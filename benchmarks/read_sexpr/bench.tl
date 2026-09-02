;# benchmarks/read_sexpr/bench.tl - the reader's recursive descent into the
;# dense Sexpr node pool.
;#
;# Equivalent to benchmarks/read_sexpr/baseline.c. The kernel is the TypeLisp
;# compiler's own s-expression reader: the mutually recursive `form-result` /
;# `list-result-with-close` descent that turns the lexer's token array into
;# `Sexpr` trees stored in a dense node pool (a list's children are one
;# contiguous id range, not a cons spine), followed by the recursive
;# `sexpr-view` walk a parser performs over the result. It runs over the real
;# token stream `src/lex.tl` produces for four compiler modules (see README.md
;# for the corpus and its regeneration command).
;#
;# Mirrored compiler functions, all in src/read.tl unless noted:
;#   form-result                -- dispatch on the token tag: Int/Float/Sym/
;#                                 Str/Char atoms, LParen -> list-result,
;#                                 LBracket -> bracket-list-result, the four
;#                                 prefix tags wrapping the following form,
;#                                 RParen/RBracket/End as errors
;#   list-result-with-close     -- the RECURSIVE element loop: read the next
;#                                 form, push it into the builder, recurse;
;#                                 the close tag seals the range with
;#                                 sexpr-list-from-builder
;#   list-result / bracket-list-result -- pool mark, fresh builder, and the
;#                                 error path that discards the builder and
;#                                 truncates the pool back to the mark
;#   prefix-tag? / prefix-symbol / prefix-form -- the two-element (quote x)
;#                                 style wrapper built through the builder
;#   sexpr-builder-new / -push / -grow! / sexpr-list-from-builder /
;#     sexpr-builder-discard!   -- the builder stack: a start index into one
;#                                 global slot array, geometric growth, and the
;#                                 single copy of the builder range into the
;#                                 node pool that seals a list
;#   sexpr-node-push / sexpr-node-pool-grow! / -truncate! / -reset! /
;#     -len / sexpr-node-get    -- the node pool: 1024 then doubling, storage
;#                                 retained across resets
;#   result / read              -- the entry point: reset the pool, read ONE
;#                                 top-level form
;#   sexpr-view                 -- the SexprView.Cons / .Nil traversal step
;#                                 over a child range
;#   ci.intern-syntax-id-from-renderable (src/compiler_intern.tl) -- the
;#                                 InternId -> InternSyntaxId transform every
;#                                 Sym atom passes through, which is the
;#                                 u32-valued id widened to u64
;#   parse-ast-program-forms-into-vec (src/compiler_parse_core.tl) -- the
;#                                 loader's drive over a whole file: one
;#                                 top-level form at a time with the pool
;#                                 bounded to a single form
;#
;# KEPT: the recursion, in both languages. `form-result` and
;# `list-result-with-close` call each other exactly as the compiler's do, and
;# the consumer walk recurses over `sexpr-view` instead of stepping an explicit
;# stack. The dense node pool, the builder stack, the pool mark / builder
;# discard error shape, the Result-returning signatures, the geometric growth
;# with retained storage, and the per-top-level-form pool reset are all the
;# compiler's.
;#
;# DROPPED: (1) `Sexpr.Int` carries its source text `String` in the compiler
;# (needed only to re-render out-of-range literals); the kernel keeps the
;# parsed value, since the text is never read on the reader's own path.
;# (2) `Sexpr.Sym` / `Sexpr.Str` carry nominal `ci.InternSyntaxId` /
;# `ci.InternId` one-field structs; the kernel carries their integer value and
;# applies the same u32 truncation `intern-syntax-id-from-renderable` performs.
;# (3) `Sexpr.Float` carries the literal text; the corpus assigns a first-
;# occurrence id for it instead (the four corpus modules contain no float
;# literal at all). (4) Error messages are `String` in the compiler and an
;# integer code here; a well-formed corpus never takes an error path, and the
;# code paths still exist so the Result match arms stay. (5) `sexpr-node-get`
;# is an unchecked `ptr-read` shared view in the compiler; here it is the
;# ordinary bounds-checked `array-ref`, which is the language-level shape this
;# gate measures. (6) The spanned reader (`form-spanned-result` and friends) is
;# the production path; it is the same descent with a `token.SourceSpan` merged
;# into every node, so the unspanned twin measures the same control flow.
;#
;# SELF-CHECK: one pass over the corpus must read exactly 3,002 top-level forms
;# and push exactly 270,063 nodes into the pool - both computed independently by
;# tools/export_tokens.py replaying the same descent. Both are asserted and
;# folded into the checksum.
;#
;# The corpus path and the round count are runtime arguments, so nothing can be
;# constant folded. Each round rotates the starting FILE by one, so no round
;# repeats an earlier round's accumulator. The checksum is a wrapping 64-bit
;# FNV-1a fold with no division, so the printed decimal matches the C
;# baseline's `%lld` bit for bit.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

;; --------------------------------------------------------------------------
;; Corpus scanning (shared with benchmarks/cfg_domloops).
;; --------------------------------------------------------------------------
(define (rs-zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (rs-vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define (rs-vec-set!
  [items : (&mut items i64vec.Vec)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(defmacro (rs-ref [items : Expr] [index : Expr]) : Expr
  `(rs-vec-ref (& ,items) ,index))

(defmacro (rs-set! [items : Expr] [index : Expr] [value : Expr]) : Expr
  `(rs-vec-set! (&mut ,items) ,index ,value))

(define rs-hash-basis : i64
  1469598103934665603)
(define rs-hash-prime : i64
  1099511628211)

(define (rs-mix [hash : i64] [value : i64]) : i64
  (* (bit-xor hash value) rs-hash-prime))

(define (rs-byte-at [text : (& text str)] [n : i64] [i : i64]) : i64
  (if (< i n)
    (cast (string.string-ref text i) : i64)
    -1))

(define (rs-digit? [byte : i64]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Whitespace-separated decimal integers, with `#` starting a comment that runs
;; to the end of its line.
(define (rs-scan-ints [text : (& text str)] [out : (&mut out i64vec.Vec)]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [byte : i64 (rs-byte-at text n i)]
          (cond
            [(= byte 35)
              (while (and (< i n) (not (= (rs-byte-at text n i) 10)))
                (set! i (+ i 1)))]
            [(or (rs-digit? byte) (= byte 45))
              (let
                [negative : bool (= byte 45)]
                [value : i64 0]
                (begin
                  (when negative (set! i (+ i 1)))
                  (while (rs-digit? (rs-byte-at text n i))
                    (begin
                      (set! value (+ (* value 10) (- (rs-byte-at text n i) 48)))
                      (set! i (+ i 1))))
                  (i64vec.set-ref!
                    out
                    count
                    (if negative
                      (- 0 value)
                      value))
                  (set! count (+ count 1))))]
            [else (set! i (+ i 1))])))
      count)))

;; --------------------------------------------------------------------------
;; src/token.tl token-kind tags, and the flattened token record.
;; --------------------------------------------------------------------------
;; `src/token.tl` stores tokens as a `defenum Token` whose payload the reader
;; reaches through one accessor per variant, and dispatches on the integer
;; `token.tag-ref` returns. The corpus already carries that integer tag and the
;; one integer payload each variant contributes to an `Sexpr`, so the token
;; stream is a flat record array indexed by the reader's cursor.
(defstruct Token
  (tag i64)
  (payload i64))

(define (tag-lparen) : i64
  1)

(define (tag-rparen) : i64
  2)

(define (tag-int) : i64
  3)

(define (tag-sym) : i64
  4)

(define (tag-end) : i64
  5)

(define (tag-str) : i64
  6)

(define (tag-char) : i64
  7)

(define (tag-float) : i64
  8)

(define (tag-lbracket) : i64
  9)

(define (tag-rbracket) : i64
  10)

(define (tag-quote) : i64
  11)

(define (tag-backtick) : i64
  12)

(define (tag-comma) : i64
  13)

(define (tag-comma-at) : i64
  14)

(define (tag-ref [t : (& t Token)]) : i64
  t.tag)

;; --------------------------------------------------------------------------
;; Dense s-expression node storage (src/read.tl).
;; --------------------------------------------------------------------------
;; TypeLisp has only proper parenthesized and bracketed forms, so a list stores
;; one contiguous range of child-node ids instead of a boxed head/tail spine.
;; The storage variants are not the traversal contract: consumers step
;; `SexprView`, whose `Cons` carries a value-level tail view.
(defenum Sexpr
  (Int i64)
  (Sym i64)
  (List i64 i64)
  (Str i64)
  (Char i64)
  (Float i64))

(defenum SexprView
  (Int i64)
  (Sym i64)
  (Nil)
  (Cons Sexpr Sexpr)
  (Str i64)
  (Char i64)
  (Float i64))

;; The compiler returns `ResultSexpr.Err String`; a well-formed corpus never
;; reaches an error arm, so the message is an integer code here and every code
;; path stays.
(defenum ResultSexpr
  (Ok Sexpr)
  (Err i64))

(defstruct SexprBuilder
  (start i64))

(define rs-err-unexpected-rparen : i64
  1)
(define rs-err-unexpected-rbracket : i64
  2)
(define rs-err-unexpected-end : i64
  3)
(define rs-err-unterminated-paren : i64
  4)
(define rs-err-unterminated-bracket : i64
  5)

;; The four symbols `prefix-symbol` names are `stable-symbol-id` literals the
;; compiler interns once and memoizes, so their concrete ids never depend on the
;; input. Four sentinels above the corpus id space keep them distinct here.
(define rs-sym-quote : i64
  1000000001)
(define rs-sym-quasiquote : i64
  1000000002)
(define rs-sym-unquote : i64
  1000000003)
(define rs-sym-unquote-splicing : i64
  1000000004)

;; The node pool and the builder stack. Two plain globals each (array + count),
;; NOT a struct, exactly as src/read.tl declares them. Storage is retained
;; across resets and never shrinks, so it is allocated at most once per
;; capacity for the whole run.
(define sexpr-node-pool-slots : (__tl_dyn-array Sexpr)
  (__tl_make-array Sexpr 0))
(define sexpr-node-pool-count : i64
  0)
(define sexpr-builder-slots : (__tl_dyn-array Sexpr)
  (__tl_make-array Sexpr 0))
(define sexpr-builder-count : i64
  0)

;; The token stream and the reader's one-element cursor cell, which src/read.tl
;; threads through the descent as a `(&mut cur (__tl_dyn-array i64))`.
(define rs-toks : (__tl_dyn-array Token)
  (__tl_make-array Token 0))
(define rs-cur : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

;; Consumer-walk accumulators, folded into the checksum once per pass.
(define rs-walk-nodes : i64
  0)
(define rs-walk-depth : i64
  0)

(define (sexpr-node-pool-len) : i64
  sexpr-node-pool-count)

;; Grow is a safety net: the pool is reset per top-level form, so it settles at
;; the largest form's node count and never grows again.
(define (sexpr-node-pool-grow!) : unit
  (let
    [old-cap : i64 (array-length sexpr-node-pool-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [new-slots : (__tl_dyn-array Sexpr) (__tl_make-array Sexpr new-cap)]
    [len : i64 sexpr-node-pool-count]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! (array-ref new-slots i) (array-ref sexpr-node-pool-slots i))
          (set! i (+ i 1))))
      (set! sexpr-node-pool-slots new-slots))))

(define (sexpr-builder-grow!) : unit
  (let
    [old-cap : i64 (array-length sexpr-builder-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [new-slots : (__tl_dyn-array Sexpr) (__tl_make-array Sexpr new-cap)]
    [i : i64 0]
    (begin
      (while (< i sexpr-builder-count)
        (begin
          (set! (array-ref new-slots i) (array-ref sexpr-builder-slots i))
          (set! i (+ i 1))))
      (set! sexpr-builder-slots new-slots))))

(define (sexpr-node-push [node : Sexpr]) : i64
  (begin
    (if (>= sexpr-node-pool-count (array-length sexpr-node-pool-slots))
      (sexpr-node-pool-grow!)
      unit)
    (let
      [id : i64 sexpr-node-pool-count]
      (begin
        (set! (array-ref sexpr-node-pool-slots id) node)
        (set! sexpr-node-pool-count (+ id 1))
        id))))

(define (sexpr-node-get [id : i64]) : Sexpr
  (array-ref sexpr-node-pool-slots id))

(define (sexpr-builder-get [id : i64]) : Sexpr
  (array-ref sexpr-builder-slots id))

(define (sexpr-node-pool-truncate! [mark : i64]) : unit
  (set! sexpr-node-pool-count mark))

(define (sexpr-node-pool-reset!) : unit
  (begin
    (sexpr-node-pool-truncate! 0)
    (set! sexpr-builder-count 0)))

(define (sexpr-builder-new) : SexprBuilder
  (SexprBuilder sexpr-builder-count))

(define (sexpr-builder-push [builder : SexprBuilder] [item : Sexpr]) : SexprBuilder
  (begin
    (if (>= sexpr-builder-count (array-length sexpr-builder-slots))
      (sexpr-builder-grow!)
      unit)
    (set! (array-ref sexpr-builder-slots sexpr-builder-count) item)
    (set! sexpr-builder-count (+ sexpr-builder-count 1))
    builder))

(define (sexpr-list-from-builder [builder : SexprBuilder]) : Sexpr
  (let
    [start : i64 (sexpr-node-pool-len)]
    [builder-start : i64 builder.start]
    [len : i64 (- sexpr-builder-count builder-start)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (sexpr-node-push (sexpr-builder-get (+ builder-start i)))
          (set! i (+ i 1))))
      (set! sexpr-builder-count builder-start)
      (Sexpr.List start len))))

(define (sexpr-builder-discard! [builder : SexprBuilder]) : unit
  (set! sexpr-builder-count builder.start))

(define (sexpr-view [s : Sexpr]) : SexprView
  (match s
    [(Sexpr.Int n) (SexprView.Int n)]
    [(Sexpr.Sym name) (SexprView.Sym name)]
    [(Sexpr.List start length)
      (if (<= length 0)
        SexprView.Nil
        (SexprView.Cons
          (sexpr-node-get start)
          (Sexpr.List (+ start 1) (- length 1))))]
    [(Sexpr.Str text) (SexprView.Str text)]
    [(Sexpr.Char c) (SexprView.Char c)]
    [(Sexpr.Float text) (SexprView.Float text)]))

;; --------------------------------------------------------------------------
;; Cursor helpers (src/read.tl).
;; --------------------------------------------------------------------------
(define (cur-pos [cur : (& cur (__tl_dyn-array i64))]) : i64
  (array-ref cur 0))

(define (peek-tag
  [toks : (& toks (__tl_dyn-array Token))]
  [cur : (& cur (__tl_dyn-array i64))]) : i64
  (tag-ref (& (array-ref toks (cur-pos cur)))))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (&mut cur (__tl_dyn-array i64))]) : unit
  (set! (array-ref cur 0) (+ (cur-pos cur) 1)))

(define (prefix-tag? [t : i64]) : bool
  (or
    (= t (tag-quote))
    (= t (tag-backtick))
    (= t (tag-comma))
    (= t (tag-comma-at))))

(define (prefix-symbol [t : i64]) : i64
  (cond
    [(= t (tag-quote)) rs-sym-quote]
    [(= t (tag-backtick)) rs-sym-quasiquote]
    [(= t (tag-comma)) rs-sym-unquote]
    [(= t (tag-comma-at)) rs-sym-unquote-splicing]
    [else rs-sym-quote]))

(define (prefix-form [name : i64] [form : Sexpr]) : Sexpr
  (sexpr-list-from-builder
    (sexpr-builder-push
      (sexpr-builder-push (sexpr-builder-new) (Sexpr.Sym name))
      form)))

;; ci.intern-syntax-id-from-renderable: `InternId` stores a `u32` and
;; `InternSyntaxId` a `u64`, so the transform every `Sexpr.Sym` payload passes
;; through is the id truncated to 32 bits and widened again.
(define (intern-syntax-id-from-renderable [id : i64]) : i64
  (bit-and id 4294967295))

;; --------------------------------------------------------------------------
;; The recursive descent (src/read.tl form-result / list-result-with-close).
;; --------------------------------------------------------------------------
(define (form-result
  [toks : (& toks (__tl_dyn-array Token))]
  [cur : (&mut cur (__tl_dyn-array i64))]) : ResultSexpr
  (let
    [tok : (& toks Token) (& (array-ref toks (cur-pos cur)))]
    [t : i64 (peek-tag toks cur)]
    (cond
      [(= t (tag-int))
        (begin
          (advance cur)
          (ResultSexpr.Ok (Sexpr.Int tok.payload)))]
      [(= t (tag-float))
        (begin
          (advance cur)
          (ResultSexpr.Ok (Sexpr.Float tok.payload)))]
      [(= t (tag-sym))
        (begin
          (advance cur)
          (ResultSexpr.Ok
            (Sexpr.Sym (intern-syntax-id-from-renderable tok.payload))))]
      [(= t (tag-str))
        (begin
          (advance cur)
          (ResultSexpr.Ok (Sexpr.Str tok.payload)))]
      [(= t (tag-char))
        (begin
          (advance cur)
          (ResultSexpr.Ok (Sexpr.Char tok.payload)))]
      [(= t (tag-lparen))
        (begin
          (advance cur)
          (list-result toks cur))]
      [(= t (tag-lbracket))
        (begin
          (advance cur)
          (bracket-list-result toks cur))]
      [(prefix-tag? t)
        (let
          [name : i64 (prefix-symbol t)]
          (begin
            (advance cur)
            (match (form-result toks cur)
              [(ResultSexpr.Ok form) (ResultSexpr.Ok (prefix-form name form))]
              [(ResultSexpr.Err message) (ResultSexpr.Err message)])))]
      [(= t (tag-rparen)) (ResultSexpr.Err rs-err-unexpected-rparen)]
      [(= t (tag-rbracket)) (ResultSexpr.Err rs-err-unexpected-rbracket)]
      [else (ResultSexpr.Err rs-err-unexpected-end)])))

;; list-result-with-close: the cursor is positioned just AFTER an opening '('.
;; Read forms until the matching ')' into a growable temporary builder;
;; completing the form copies that builder once into a contiguous child range in
;; source order. Nesting is handled for free: a head form that starts with '('
;; re-enters `form-result` -> `list-result`, completes its own child range, and
;; then becomes one value in this builder.
(define (list-result-with-close
  [toks : (& toks (__tl_dyn-array Token))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [close-tag : i64]
  [unterminated-message : i64]
  [builder : SexprBuilder]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (if (= t close-tag)
      ;; End of this list: consume the ')' and seal the dense child range.
      (begin
        (advance cur)
        (ResultSexpr.Ok (sexpr-list-from-builder builder)))
      (if (= t (tag-end))
        (ResultSexpr.Err unterminated-message)
        ;; A list element: read the next form (which advances the cursor past
        ;; it, however deeply nested), append it, and continue.
        (match (form-result toks cur)
          [(ResultSexpr.Ok head)
            (list-result-with-close
              toks
              cur
              close-tag
              unterminated-message
              (sexpr-builder-push builder head))]
          [(ResultSexpr.Err message) (ResultSexpr.Err message)])))))

(define (list-result
  [toks : (& toks (__tl_dyn-array Token))]
  [cur : (&mut cur (__tl_dyn-array i64))]) : ResultSexpr
  (let
    [pool-mark : i64 (sexpr-node-pool-len)]
    [builder : SexprBuilder (sexpr-builder-new)]
    [result : ResultSexpr
      (list-result-with-close
        toks
        cur
        (tag-rparen)
        rs-err-unterminated-paren
        builder)]
    (match result
      [(ResultSexpr.Ok form) (ResultSexpr.Ok form)]
      [(ResultSexpr.Err message)
        (begin
          (sexpr-builder-discard! builder)
          (sexpr-node-pool-truncate! pool-mark)
          (ResultSexpr.Err message))])))

(define (bracket-list-result
  [toks : (& toks (__tl_dyn-array Token))]
  [cur : (&mut cur (__tl_dyn-array i64))]) : ResultSexpr
  (let
    [pool-mark : i64 (sexpr-node-pool-len)]
    [builder : SexprBuilder (sexpr-builder-new)]
    [result : ResultSexpr
      (list-result-with-close
        toks
        cur
        (tag-rbracket)
        rs-err-unterminated-bracket
        builder)]
    (match result
      [(ResultSexpr.Ok form) (ResultSexpr.Ok form)]
      [(ResultSexpr.Err message)
        (begin
          (sexpr-builder-discard! builder)
          (sexpr-node-pool-truncate! pool-mark)
          (ResultSexpr.Err message))])))

;; `read.result`: reset the pool, then read one top-level form. The compiler's
;; `result` also rewinds the cursor to zero because it reads a single datum; the
;; loader (`parse-ast-program-forms-into-vec`) instead threads one cursor across
;; a whole file and bounds the pool to a single form, which is what the driver
;; below does.
(define (rs-result) : ResultSexpr
  (begin
    (sexpr-node-pool-reset!)
    (form-result (& rs-toks) (&mut rs-cur))))

;; `read`: the panicking wrapper the loader's non-diagnostic path uses.
(define (rs-read) : Sexpr
  (match (rs-result)
    [(ResultSexpr.Ok form) form]
    [(ResultSexpr.Err _) (io.panic "reader: malformed corpus")]))

;; --------------------------------------------------------------------------
;; The consumer: the recursive `sexpr-view` walk a parser performs.
;; --------------------------------------------------------------------------
(define (sexpr-walk [s : Sexpr] [depth : i64] [hash : i64]) : i64
  (begin
    (set! rs-walk-nodes (+ rs-walk-nodes 1))
    (when (> depth rs-walk-depth) (set! rs-walk-depth depth))
    (match (sexpr-view s)
      [(SexprView.Int value) (rs-mix hash value)]
      [(SexprView.Sym name) (rs-mix hash name)]
      [(SexprView.Nil) (rs-mix hash depth)]
      [(SexprView.Cons head tail)
        (sexpr-walk tail depth (sexpr-walk head (+ depth 1) hash))]
      [(SexprView.Str text) (rs-mix hash text)]
      [(SexprView.Char c) (rs-mix hash c)]
      [(SexprView.Float text) (rs-mix hash text)])))

;; --------------------------------------------------------------------------
;; Driver.
;; --------------------------------------------------------------------------
;; One file: the loader's top-level loop. Read forms until the file's `End`
;; token, resetting the pool before each one, and walk every form the way
;; `parse-ast-decl-maybe-with-pools` walks it.
(define (rs-file [start : i64] [hash : i64]) : i64
  (let
    [acc : i64 hash]
    (begin
      (set! (array-ref rs-cur 0) start)
      (while (not (= (peek-tag (& rs-toks) (& rs-cur)) (tag-end)))
        (let
          [form : Sexpr (rs-read)]
          (begin
            (set! rs-forms (+ rs-forms 1))
            (set! rs-nodes (+ rs-nodes (sexpr-node-pool-len)))
            (set! acc (sexpr-walk form 0 acc)))))
      acc)))

;; Per-pass self-check counters.
(define rs-forms : i64
  0)
(define rs-nodes : i64
  0)

;; The values tools/export_tokens.py computes by replaying the same descent over
;; data/tokens.txt. Any drift in the reader or the corpus fails here.
(define rs-expect-forms : i64
  3002)
(define rs-expect-nodes : i64
  270063)
(define rs-file-start : i64vec.Vec
  (rs-zero-vec 1))

(define (rs-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (byte_buf.to-string (io.read-file path))]
    [capacity : i64 (+ (/ (string.string-length text) 2) 8)]
    [tokens : i64vec.Vec (rs-zero-vec capacity)]
    [scanned : i64 0]
    [ntokens : i64 0]
    [nfiles : i64 0]
    [round : i64 0]
    [start : i64 0]
    [acc : i64 rs-hash-basis]
    (begin
      (set! scanned (rs-scan-ints (& text) (&mut tokens)))
      (set! acc (rs-mix acc scanned))
      (set! ntokens (rs-ref tokens 0))
      (set! nfiles (rs-ref tokens 1))
      (set! rs-file-start (rs-zero-vec (+ nfiles 1)))
      (set! rs-toks (__tl_make-array Token ntokens))
      (let
        [i : i64 0]
        [files : i64 0]
        (begin
          (rs-set! rs-file-start 0 0)
          (set! files 1)
          (while (< i ntokens)
            (let
              [tag : i64 (rs-ref tokens (+ 2 (* i 2)))]
              (begin
                (set!
                  (array-ref rs-toks i)
                  (Token tag (rs-ref tokens (+ 3 (* i 2)))))
                (when
                  (and (= tag (tag-end)) (< files nfiles))
                  (begin
                    (rs-set! rs-file-start files (+ i 1))
                    (set! files (+ files 1))))
                (set! i (+ i 1)))))))
      (while (< round rounds)
        (let
          [step : i64 0]
          [index : i64 0]
          (begin
            (set! acc (rs-mix acc round))
            (set! rs-forms 0)
            (set! rs-nodes 0)
            (set! rs-walk-nodes 0)
            (set! rs-walk-depth 0)
            (while (< step nfiles)
              (begin
                (set! index (+ start step))
                (when (>= index nfiles) (set! index (- index nfiles)))
                (set! acc (rs-file (rs-ref rs-file-start index) acc))
                (set! step (+ step 1))))
            (when
              (or
                (not (= rs-forms rs-expect-forms))
                (not (= rs-nodes rs-expect-nodes)))
              (io.panic "read_sexpr: self-check failed"))
            (set! acc (rs-mix acc rs-forms))
            (set! acc (rs-mix acc rs-nodes))
            (set! acc (rs-mix acc rs-walk-nodes))
            (set! acc (rs-mix acc rs-walk-depth))
            (set! start (+ start 1))
            (when (>= start nfiles) (set! start 0))
            (set! round (+ round 1)))))
      acc)))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.println "{}" (rs-bench path rounds))
      0)))