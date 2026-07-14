;; read.tl - The s-expression READER for TypeLisp's own syntax, factored out
;; as a `main`-less, importable module.
;;
;; --------------------------------------------------------------------------
;; Why this module exists (the module signal for reusable reader code).
;; --------------------------------------------------------------------------
;; `reader.tl` is the *demo* program for the s-expression reader: it carries a
;; `main` that reads a sample and folds the resulting tree with `sum-ints`.
;; Reusable frontend modules need the reader's `read : (-> (Array token.Token) Sexpr)`
;; and the `Sexpr` AST it builds without inheriting that demo `main`.
;;
;; The legacy stage0 module loader is whole-program: it concatenates every
;; imported module's declarations into a single program, then runs the unchanged
;; `typecheck -> lower -> codegen` pipeline. So two modules that both declare a
;; `main` and are loaded together produce a duplicate `main` symbol. The
;; selfhost namespace model specified in SPEC.md replaces
;; this flat import behavior with qualified module identities. Importing
;; `reader.tl` (which HAS a `main`) into another command driver that also needs
;; a `main` would clash.
;;
;; The fix is this `main`-less module: it holds the reader's cursor helpers, the
;; mutually recursive `read-form` / `read-list`, the public `read` entry, AND the
;; `Sexpr` AST definition. Callers that need to turn source text into tokens
;; import `lex.tl` alongside this reader module. This module imports the `token`
;; module for token types and declares NO `main`.
;; Command drivers and compiler modules can import it and still produce a
;; concatenated program with exactly one `main`. `reader.tl` stays as the
;; reader's standalone demo. This mirrors how `lex.tl` was factored from the
;; `main`-bearing `lexer.tl`: a `main`-less module is the unit of reuse, a
;; `main`-bearing file is a runnable demo.
(module read)

(import stdlib.io)
(import stdlib.arena)
(import stdlib.string)
(import token)

;; --------------------------------------------------------------------------
;; The Sexpr AST: cons cells, the way Lisp represents read source.
;; --------------------------------------------------------------------------
;; An s-expression is an atom (an integer, float, or symbol), the empty list, or a cons
;; cell pairing a head s-expression with a tail s-expression. A *proper list*
;; `(a b c)` is the right-nested spine
;; `(Sexpr.Cons a (Sexpr.Cons b (Sexpr.Cons c Sexpr.Nil)))`, terminated by
;; `Sexpr.Nil` - exactly the cons-cell encoding of a list in any Lisp.
;; `Sexpr.Cons` carries two boxed `Sexpr` children, so the recursive layout is
;; finite and every constructed node that escapes via a return is heap-promoted.
;; The reader builds this tree; importers can walk it with `match`-based
;; recursion. `Sexpr.Str` carries the inner text of a `"..."` string-literal
;; datum: the reader consumes the lexer's `token.Token.Str` token into it, so a
;; quoted string reads as a distinct atom rather than being conflated with a
;; `Sexpr.Sym` of the same characters. `Sexpr.Char` carries a character-literal
;; datum (`'x'`), likewise keeping chars distinct from symbols, ints, and strings. `Sexpr.Str` and `Sexpr.Char`
;; are appended last so the existing variants keep their stable ordering for
;; every importer.
(defenum Sexpr
  (Int i64 String)
  (Sym String)
  (Nil)
  (Cons (Box Sexpr) (Box Sexpr))
  (Str String)
  (Char char)
  (Float String))

(defenum ResultSexpr
  (Ok Sexpr)
  (Err String))

(defenum SpannedSexpr
  (Int i64 String token.SourceSpan)
  (Sym String token.SourceSpan)
  (Nil token.SourceSpan)
  (Cons i64 i64 token.SourceSpan)
  (Str String token.SourceSpan)
  (Char char token.SourceSpan)
  (Float String token.SourceSpan)
  (BracketList i64 token.SourceSpan))

(defenum ResultSpannedSexpr
  (Ok SpannedSexpr)
  (Err token.SourceError))

;; --- flat SpannedSexpr node pool (mirrors the AstExpr flat pool) ---
;; SpannedSexpr.Cons / SpannedSexpr.BracketList children are i64 ids into this pool instead of
;; (box ...). Two plain globals (array + count), NOT a struct, to avoid the
;; opt2 hot-path-inline miscompile seen on the AstExpr pool. The spanned tree
;; is transient (consumed into AstExpr, spans copied out by value, then dead),
;; so the pool is reset per program parse (see compiler_parse_core.tl).
(define sp-node-pool-slots : (Array SpannedSexpr)
  (make-array SpannedSexpr 262144))

;; The backing array is process-global. Capture its arena after the initial
;; allocation so a safety-net grow cannot accidentally move it into a
;; short-lived parser/test arena and leave this global dangling when that arena
;; is destroyed.
(define sp-node-pool-base-arena : i64
  (arena.tl_arena_current))
(define sp-node-pool-count : i64
  0)

(define (sp-node-pool-restore-arena-after-base-alloc!
  [previous-arena : i64]
  [base-arena : i64]
  [head-arena : i64]) : unit
  (unsafe
    (arena.tl_arena_set
      (if (= previous-arena base-arena)
        head-arena
        previous-arena))))

(define (sp-node-pool-len) : i64
  sp-node-pool-count)

;; Grow is a safety net. The spanned pool is reset per program parse and
;; truncated per top-level form (compiler_parse_core.tl), so ordinary inputs
;; stay under the initial capacity. Large generated/selfhost closures can still
;; reach it. Growing reassigns the global mid-push, so allocate in the
;; persistent base arena just like the AST/type node pools do; otherwise a grow
;; from a transient file/test arena leaves the global dangling at teardown.
(define (sp-node-pool-grow!) : unit
  (let
    [old-slots : (Array SpannedSexpr) sp-node-pool-slots]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [previous-arena : i64 (arena.tl_arena_current)]
    [base-arena : i64 sp-node-pool-base-arena]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set base-arena))]
    [new-slots : (Array SpannedSexpr) (make-array SpannedSexpr new-cap)]
    [head-arena : i64 (arena.tl_arena_current)]
    [_restore-arena : unit
      (sp-node-pool-restore-arena-after-base-alloc!
        previous-arena
        base-arena
        head-arena)]
    [len : i64 sp-node-pool-count]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
      (set! sp-node-pool-base-arena head-arena)
      (set! sp-node-pool-slots new-slots))))

(define (sp-node-push [node : SpannedSexpr]) : i64
  (begin
    (if (>= sp-node-pool-count (array-length sp-node-pool-slots))
      (sp-node-pool-grow!)
      unit)
    (let
      [id : i64 sp-node-pool-count]
      (begin
        (array-set! sp-node-pool-slots id node)
        (set! sp-node-pool-count (+ id 1))
        id))))

(define (sp-node-get [id : i64]) : SpannedSexpr
  (array-ref sp-node-pool-slots id))

(define (sp-node-pool-truncate! [mark : i64]) : unit
  (set! sp-node-pool-count mark))

(define (sp-node-pool-reset!) : unit
  (sp-node-pool-truncate! 0))

(define (sp-node-pool-arena-ownership-self-test) : i64
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (begin
      (unsafe
        (arena.set! scratch))
      (sp-node-pool-grow!)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)))
      (sp-node-pool-reset!)
      (let
        [id : i64 (sp-node-push (SpannedSexpr.Nil (token.SourceSpan 1 1 1 1)))]
        (match (sp-node-get id)
          [(SpannedSexpr.Nil span)
            (if (and (= id 0) (= (struct-get span start-line) 1))
              42
              1)]
          [_ 2])))))

(define (sexpr-cons [head : Sexpr] [tail : Sexpr]) : Sexpr
  (Sexpr.Cons (box head) (box tail)))

(define (spanned-sexpr-cons
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (SpannedSexpr.Cons (sp-node-push head) (sp-node-push tail) span))

(define (spanned-sexpr-bracket-list
  [items : SpannedSexpr]
  [span : token.SourceSpan]) : SpannedSexpr
  (SpannedSexpr.BracketList (sp-node-push items) span))

(define (spanned-sexpr-span [s : SpannedSexpr]) : token.SourceSpan
  (match s
    [(SpannedSexpr.Int _ _ span) span]
    [(SpannedSexpr.Sym _ span) span]
    [(SpannedSexpr.Nil span) span]
    [(SpannedSexpr.Cons _ _ span) span]
    [(SpannedSexpr.Str _ span) span]
    [(SpannedSexpr.Char _ span) span]
    [(SpannedSexpr.Float _ span) span]
    [(SpannedSexpr.BracketList _ span) span]))

(define (spanned-sexpr-form [s : SpannedSexpr]) : Sexpr
  (match s
    [(SpannedSexpr.Int n text _) (Sexpr.Int n text)]
    [(SpannedSexpr.Sym sym _) (Sexpr.Sym sym)]
    [(SpannedSexpr.Nil _) Sexpr.Nil]
    [(SpannedSexpr.Cons head tail _)
      (sexpr-cons
        (spanned-sexpr-form (sp-node-get head))
        (spanned-sexpr-form (sp-node-get tail)))]
    [(SpannedSexpr.Str text _) (Sexpr.Str text)]
    [(SpannedSexpr.Char c _) (Sexpr.Char c)]
    [(SpannedSexpr.Float text _) (Sexpr.Float text)]
    [(SpannedSexpr.BracketList items _)
      (spanned-sexpr-form (sp-node-get items))]))

;; --------------------------------------------------------------------------
;; The reader cursor: a single mutable index into the `(Array token.Token)`.
;; --------------------------------------------------------------------------
;; A TypeLisp function returns a single value, but the reader must both *return
;; an `Sexpr`* and *advance past the tokens it consumed*. So the position is an
;; out-param: a single-cell `(Array i64)` (`cur`) holding the index of the token
;; under the cursor. Because arrays are heap references, a mutation through `cur`
;; is visible to the caller across the recursive `read-form` / `read-list` calls.
;; Current cursor position (index of the token under the cursor).
(define (cur-pos [cur : (Array i64)]) : i64
  (array-ref cur 0))

;; Kind tag of the token under the cursor, via the imported `token.tag`. This is
;; the load-bearing cross-import call: the reader classifies a `token.Token` produced
;; by the imported `lex` using the accessor defined in the imported token model.
(define (peek-tag [toks : (Array token.Token)] [cur : (Array i64)]) : i64
  (token.tag (array-ref toks (cur-pos cur))))

;; The `token.Token` value under the cursor (for projecting its int/symbol payload).
(define (peek-tok [toks : (Array token.Token)] [cur : (Array i64)]) : token.Token
  (array-ref toks (cur-pos cur)))

(define (peek-spanned-token
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : token.SpannedToken
  (array-ref toks (cur-pos cur)))

(define (peek-spanned-tag
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : i64
  (token.tag (token.spanned-token-token (peek-spanned-token toks cur))))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (Array i64)]) : unit
  (array-set! cur 0 (+ (cur-pos cur) 1)))

(define (read-prefix-tag? [t : i64]) : bool
  (or
    (= t (token.tag-quote))
    (= t (token.tag-backtick))
    (= t (token.tag-comma))
    (= t (token.tag-comma-at))))

(define (read-prefix-symbol [t : i64]) : String
  (cond
    [(= t (token.tag-quote)) "quote"]
    [(= t (token.tag-backtick)) "quasiquote"]
    [(= t (token.tag-comma)) "unquote"]
    [(= t (token.tag-comma-at)) "unquote-splicing"]
    [else "quote"]))

(define (read-prefix-form [name : String] [form : Sexpr]) : Sexpr
  (sexpr-cons (Sexpr.Sym name) (sexpr-cons form Sexpr.Nil)))

(define (read-prefix-spanned-form
  [name : String]
  [prefix-span : token.SourceSpan]
  [form : SpannedSexpr]) : SpannedSexpr
  (let
    [span : token.SourceSpan
      (token.merge-spans prefix-span (spanned-sexpr-span form))]
    (spanned-sexpr-cons
      (SpannedSexpr.Sym name prefix-span)
      (spanned-sexpr-cons
        form
        (SpannedSexpr.Nil (spanned-sexpr-span form))
        span)
      span)))

(define (read-close-delimiter-text [tag : i64]) : String
  (if (= tag (token.tag-rparen))
    ")"
    (if (= tag (token.tag-rbracket))
      "]"
      "?")))

(define (read-quoted-close-delimiter [tag : i64]) : String
  (string.append "'" (string.append (read-close-delimiter-text tag) "'")))

(define (read-opposite-close-delimiter? [tag : i64] [expected : i64]) : bool
  (if (= expected (token.tag-rparen))
    (= tag (token.tag-rbracket))
    (if (= expected (token.tag-rbracket))
      (= tag (token.tag-rparen))
      false)))

(define (read-span-location [span : token.SourceSpan]) : String
  (string.append
    (string.int->string (token.span-start-line span))
    (string.append ":" (string.int->string (token.span-start-col span)))))

(define (read-unterminated-list-message [expected : i64]) : String
  (string.append
    "reader: unterminated list: reached end of input before "
    (read-quoted-close-delimiter expected)))

(define (read-mismatched-close-message
  [expected : i64]
  [actual : i64]
  [actual-span : token.SourceSpan]) : String
  (string.append
    "reader: mismatched delimiter: expected "
    (string.append
      (read-quoted-close-delimiter expected)
      (string.append
        " but found "
        (string.append
          (read-quoted-close-delimiter actual)
          (string.append " at " (read-span-location actual-span)))))))

;; --------------------------------------------------------------------------
;; The reader proper: `read-form` and `read-list`, mutually recursive.
;; --------------------------------------------------------------------------
;; read-form: read exactly one s-expression starting at the cursor and return
;; it, advancing the cursor past the tokens it consumed.
;;   token.Token.Int n text -> Sexpr.Int n text  an integer atom with source spelling
;;   token.Token.Float s -> Sexpr.Float s        a float atom carrying source text
;;   token.Token.Sym s -> Sexpr.Sym s            a symbol atom
;;   token.Token.Str s -> Sexpr.Str s            a string-literal atom (`"..."`)
;;   token.Token.Char c -> Sexpr.Char c          a character-literal atom (`'x'`)
;;   token.Token.LParen -> read-list             consume '(' then read a list to its ')'
;;   token.Token.RParen -> error                 a stray ')' with no opening '(' is malformed
;;   token.Token.End -> error                    end of stream where a form was expected
;; A grammar violation returns a recoverable `ErrSexpr String`; the compatibility
;; wrappers below still panic for callers that have not moved to `read-result`.
(define (read-form-spanned-result
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]) : ResultSpannedSexpr
  (let
    [st : token.SpannedToken (peek-spanned-token toks cur)]
    [tok : token.Token (token.spanned-token-token st)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    [t : i64 (token.tag tok)]
    (cond
      [(= t (token.tag-int))
        (let
          [v : i64 (token.int tok)]
          [text : String (token.int-text tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Int v text span))))]
      [(= t (token.tag-float))
        (let
          [s : String (token.float tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Float s span))))]
      [(= t (token.tag-sym))
        (let
          [s : String (token.sym tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Sym s span))))]
      [(= t (token.tag-str))
        (let
          [s : String (token.str tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Str s span))))]
      [(= t (token.tag-char))
        (let
          [c : char (token.char tok)]
          (begin
            (advance cur)
            (ResultSpannedSexpr.Ok (SpannedSexpr.Char c span))))]
      [(= t (token.tag-lparen))
        (begin
          (advance cur)
          (read-list-spanned-result toks cur span))]
      [(= t (token.tag-lbracket))
        (begin
          (advance cur)
          (read-bracket-list-spanned-result toks cur span))]
      [(read-prefix-tag? t)
        (let
          [name : String (read-prefix-symbol t)]
          (begin
            (advance cur)
            (match (read-form-spanned-result toks cur)
              [(ResultSpannedSexpr.Ok form)
                (ResultSpannedSexpr.Ok
                  (read-prefix-spanned-form name span form))]
              [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)])))]
      [(= t (token.tag-rparen))
        (ResultSpannedSexpr.Err
          (token.SourceError "reader: unexpected ')'" span))]
      [(= t (token.tag-rbracket))
        (ResultSpannedSexpr.Err
          (token.SourceError "reader: unexpected ']'" span))]
      [else
        (ResultSpannedSexpr.Err
          (token.SourceError "reader: unexpected end of input" span))])))

(define (read-list-spanned-items-result
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [open-span : token.SourceSpan]
  [close-tag : i64]) : ResultSpannedSexpr
  (let
    [st : token.SpannedToken (peek-spanned-token toks cur)]
    [span : token.SourceSpan (token.spanned-token-span st)]
    [t : i64 (token.tag (token.spanned-token-token st))]
    (cond
      [(= t close-tag)
        (begin
          (advance cur)
          (ResultSpannedSexpr.Ok
            (SpannedSexpr.Nil (token.merge-spans open-span span))))]
      [(= t (token.tag-end))
        (ResultSpannedSexpr.Err
          (token.SourceError
            (read-unterminated-list-message close-tag)
            open-span))]
      [(read-opposite-close-delimiter? t close-tag)
        (ResultSpannedSexpr.Err
          (token.SourceError
            (read-mismatched-close-message close-tag t span)
            span))]
      [else
        (match (read-form-spanned-result toks cur)
          [(ResultSpannedSexpr.Ok head)
            (match (read-list-spanned-items-result toks cur open-span close-tag)
              [(ResultSpannedSexpr.Ok tail)
                (ResultSpannedSexpr.Ok
                  (spanned-sexpr-cons
                    head
                    tail
                    (token.merge-spans open-span (spanned-sexpr-span tail))))]
              [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)])]
          [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)])])))

(define (read-list-spanned-result
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [open-span : token.SourceSpan]) : ResultSpannedSexpr
  (read-list-spanned-items-result toks cur open-span (token.tag-rparen)))

(define (read-bracket-list-spanned-result
  [toks : (Array token.SpannedToken)]
  [cur : (Array i64)]
  [open-span : token.SourceSpan]) : ResultSpannedSexpr
  (match (read-list-spanned-items-result
    toks
    cur
    open-span
    (token.tag-rbracket))
    [(ResultSpannedSexpr.Ok items)
      (ResultSpannedSexpr.Ok
        (spanned-sexpr-bracket-list items (spanned-sexpr-span items)))]
    [(ResultSpannedSexpr.Err err) (ResultSpannedSexpr.Err err)]))

(define (read-form-result [toks : (Array token.Token)] [cur : (Array i64)]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (cond
      [(= t (token.tag-int))
        (let
          [tok : token.Token (peek-tok toks cur)]
          [v : i64 (token.int tok)]
          [text : String (token.int-text tok)]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Int v text))))]
      [(= t (token.tag-float))
        (let
          [s : String (token.float (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Float s))))]
      [(= t (token.tag-sym))
        (let
          [s : String (token.sym (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Sym s))))]
      [(= t (token.tag-str))
        (let
          [s : String (token.str (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Str s))))]
      [(= t (token.tag-char))
        (let
          [c : char (token.char (peek-tok toks cur))]
          (begin
            (advance cur)
            (ResultSexpr.Ok (Sexpr.Char c))))]
      [(= t (token.tag-lparen))
        (begin
          (advance cur)
          (read-list-result toks cur))]
      [(= t (token.tag-lbracket))
        (begin
          (advance cur)
          (read-bracket-list-result toks cur))]
      [(read-prefix-tag? t)
        (let
          [name : String (read-prefix-symbol t)]
          (begin
            (advance cur)
            (match (read-form-result toks cur)
              [(ResultSexpr.Ok form)
                (ResultSexpr.Ok (read-prefix-form name form))]
              [(ResultSexpr.Err message) (ResultSexpr.Err message)])))]
      [(= t (token.tag-rparen)) (ResultSexpr.Err "reader: unexpected ')'")]
      [(= t (token.tag-rbracket)) (ResultSexpr.Err "reader: unexpected ']'")]
      [else (ResultSexpr.Err "reader: unexpected end of input")])))

;; read-list: the cursor is positioned just AFTER an opening '('. Read forms
;; until the matching ')', returning the proper list
;; `(Sexpr.Cons f1 (Sexpr.Cons f2 ... Sexpr.Nil))`. Built by right-recursion so
;; the spine comes out in source order
;; with NO reversal: read the head form, then recurse to read the rest of the
;; list, and cons the two. The base case is the ')' that closes this list -
;; consume it and return `Sexpr.Nil`. Hitting `token.Token.End` before a ')' is an unterminated
;; list and returns `ErrSexpr`. Nesting is handled for free: a head form that is
;; itself a '(' re-enters `read-form-result` -> `read-list-result`, which reads
;; the inner list to ITS ')' and advances the shared cursor past it before this
;; level reads its next sibling.
(define (read-list-result-with-close
  [toks : (Array token.Token)]
  [cur : (Array i64)]
  [close-tag : i64]
  [unterminated-message : String]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (if (= t close-tag)
      ;; End of this list: consume the ')' and terminate the spine with `Sexpr.Nil`.
      (begin
        (advance cur)
        (ResultSexpr.Ok Sexpr.Nil))
      (if (= t (token.tag-end))
        (ResultSexpr.Err unterminated-message)
        ;; A list element: read the head form (which advances the cursor past
        ;; it, however deeply nested), then recurse for the tail and cons.
        (match (read-form-result toks cur)
          [(ResultSexpr.Ok head)
            (match (read-list-result-with-close
              toks
              cur
              close-tag
              unterminated-message)
              [(ResultSexpr.Ok tail) (ResultSexpr.Ok (sexpr-cons head tail))]
              [(ResultSexpr.Err message) (ResultSexpr.Err message)])]
          [(ResultSexpr.Err message) (ResultSexpr.Err message)])))))

(define (read-list-result [toks : (Array token.Token)] [cur : (Array i64)]) : ResultSexpr
  (read-list-result-with-close
    toks
    cur
    (token.tag-rparen)
    "reader: unterminated list (missing ')')"))

(define (read-bracket-list-result
  [toks : (Array token.Token)]
  [cur : (Array i64)]) : ResultSexpr
  (read-list-result-with-close
    toks
    cur
    (token.tag-rbracket)
    "reader: unterminated list (missing ']')"))

(define (read-form [toks : (Array token.Token)] [cur : (Array i64)]) : Sexpr
  (match (read-form-result toks cur)
    [(ResultSexpr.Ok form) form]
    [(ResultSexpr.Err message) (io.panic message)]))

(define (read-list [toks : (Array token.Token)] [cur : (Array i64)]) : Sexpr
  (match (read-list-result toks cur)
    [(ResultSexpr.Ok list) list]
    [(ResultSexpr.Err message) (io.panic message)]))

;; read: the public entry point. Read a single top-level form from the front of
;; `toks` (a cursor starting at index 0) and return its `Sexpr` tree. (Trailing
;; tokens after the first form are ignored here, as a top-level `read` returns
;; one datum at a time.)
(define (read-result [toks : (Array token.Token)]) : ResultSexpr
  (let
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (read-form-result toks cur))))

(define (read-spanned-result [toks : (Array token.SpannedToken)]) : ResultSpannedSexpr
  (let
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (read-form-spanned-result toks cur))))

(define (read-spanned [toks : (Array token.SpannedToken)]) : SpannedSexpr
  (match (read-spanned-result toks)
    [(ResultSpannedSexpr.Ok form) form]
    [(ResultSpannedSexpr.Err err) (io.panic (token.source-error-message err))]))

(define (read [toks : (Array token.Token)]) : Sexpr
  (match (read-result toks)
    [(ResultSexpr.Ok form) form]
    [(ResultSexpr.Err message) (io.panic message)]))