;; reader.tl - The s-expression READER for TypeLisp's own syntax: the
;; canonical Lisp reader, written in TypeLisp itself. The second component of
;; TypeLisp's self-hosting compiler front end (#27), following the tokenizer.
;;
;; Where the lexer (`lex.tl`) turns a source String into a flat
;; `(Array Token)` - balanced parens, integer literals, and symbols - the reader
;; turns that token stream into the recursive cons-cell tree those parens
;; describe: the `Sexpr` AST. This is exactly the `read` of a real Lisp: the
;; data structure a TypeLisp compiler's later passes (macroexpansion, the
;; special-form/`define` analyzer, lowering) walk over.
;;
;;   String --lex--> (Array Token) --read--> Sexpr
;;
;; --------------------------------------------------------------------------
;; How the lexer is reused (the KEY module signal, refs #44/#81).
;; --------------------------------------------------------------------------
;; The reader does NOT re-derive tokenization. It `(import "lex.tl")`s the
;; lexer's public `lex : (-> String (Array Token))`, factored into a `main`-less
;; module precisely so it can be shared. `lex.tl` in turn imports the
;; `main`-less `token.tl` token model, so this single import transitively
;; pulls in BOTH the `lex` entry and the `Token` enum + token accessors/tag
;; constants.
;;
;; The legacy stage0 module loader (#44) is whole-program: it concatenates every
;; reachable module's declarations (post-order DFS: imported-before-importer),
;; then runs the unchanged pipeline. So the load order is `token.tl`, then
;; `lex.tl`, then this file. Crucially, NONE of the imported modules declares a
;; `main` - only this reader does - so the concatenated program has exactly one
;; `main` and there is no duplicate-symbol clash. The selfhost namespace model
;; specified in SPEC.md replaces this flat import behavior with qualified module
;; identities.
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(import "../stdlib/io.tl")

(import "lex.tl")

;; --------------------------------------------------------------------------
;; The Sexpr AST: cons cells, the way Lisp represents read source (refs #13/#27).
;; --------------------------------------------------------------------------
;; An s-expression is an atom (an integer, float, or symbol), the empty list, or a cons
;; cell pairing a head s-expression with a tail s-expression. A *proper list*
;; `(a b c)` is the right-nested spine `(SCons a (SCons b (SCons c (SNil))))`,
;; terminated by `SNil` - exactly the cons-cell encoding of a list in any Lisp.
;; `SCons` carries two boxed `Sexpr` children, so the recursive layout is finite
;; and every constructed node that escapes via a return is heap-promoted. The
;; reader builds this tree; a `match`-based fold walks it.
;; `SStr` carries the inner text of a `"..."` string-literal datum: the reader
;; consumes the lexer's `TStr` token (#128) into it, so a quoted string reads as a
;; distinct atom rather than being conflated with a `SSym` of the same characters.
;; `SChar` carries a `#x'` / `#\x'` character-literal datum (#333), likewise
;; keeping chars distinct from symbols, ints, and strings. `SStr` and `SChar`
;; are appended last so the existing variants keep their stable ordering.
(defenum Sexpr
  (SInt i64)
  (SSym String)
  (SNil)
  (SCons (Box Sexpr) (Box Sexpr))
  (SStr String)
  (SChar char)
  (SFloat String))

(defenum ResultSexpr
  (OkSexpr Sexpr)
  (ErrSexpr String))

(defenum SpannedSexpr
  (SpSInt i64 SourceSpan)
  (SpSSym String SourceSpan)
  (SpSNil SourceSpan)
  (SpSCons (Box SpannedSexpr) (Box SpannedSexpr) SourceSpan)
  (SpSStr String SourceSpan)
  (SpSChar char SourceSpan)
  (SpSFloat String SourceSpan)
  (SpSBracketList (Box SpannedSexpr) SourceSpan))

(defenum ResultSpannedSexpr
  (OkSpannedSexpr SpannedSexpr)
  (ErrSpannedSexpr SourceError))

(define (sexpr-cons [head : Sexpr] [tail : Sexpr]) : Sexpr
  (SCons (box head) (box tail)))

(define (spanned-sexpr-cons
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : SourceSpan]) : SpannedSexpr
  (SpSCons (box head) (box tail) span))

(define (spanned-sexpr-bracket-list [items : SpannedSexpr] [span : SourceSpan]) : SpannedSexpr
  (SpSBracketList (box items) span))

(define (spanned-sexpr-span [s : SpannedSexpr]) : SourceSpan
  (match s
    [(SpSInt _ span) span]
    [(SpSSym _ span) span]
    [(SpSNil span) span]
    [(SpSCons _ _ span) span]
    [(SpSStr _ span) span]
    [(SpSChar _ span) span]
    [(SpSFloat _ span) span]
    [(SpSBracketList _ span) span]))

(define (spanned-sexpr-form [s : SpannedSexpr]) : Sexpr
  (match s
    [(SpSInt n _) (SInt n)]
    [(SpSSym sym _) (SSym sym)]
    [(SpSNil _) SNil]
    [(SpSCons head tail _)
      (sexpr-cons
        (spanned-sexpr-form (box-get head))
        (spanned-sexpr-form (box-get tail)))]
    [(SpSStr text _) (SStr text)]
    [(SpSChar c _) (SChar c)]
    [(SpSFloat text _) (SFloat text)]
    [(SpSBracketList items _) (spanned-sexpr-form (box-get items))]))

;; --------------------------------------------------------------------------
;; The reader cursor: a single mutable index into the `(Array Token)`.
;; --------------------------------------------------------------------------
;; A TypeLisp function returns a single value, but the reader must both *return
;; an `Sexpr`* and *advance past the tokens it consumed*. So the position is an
;; out-param: a single-cell `(Array i64)` (`cur`) holding the index of the token
;; under the cursor. Because arrays are heap references, a mutation through `cur`
;; is visible to the caller across the recursive `read-form` / `read-list` calls.
;; This is the same cursor-threading the recursive-descent parser uses.
;; Current cursor position (index of the token under the cursor).
(define (cur-pos [cur : (Array i64)]) : i64
  (array-ref cur 0))

;; Kind tag of the token under the cursor, via the imported `token-tag`. This is
;; the load-bearing cross-import call: the reader classifies a `Token` produced
;; by the imported `lex` using the accessor defined in the imported token model.
(define (peek-tag [toks : (Array Token)] [cur : (Array i64)]) : i64
  (token-tag (array-ref toks (cur-pos cur))))

;; The `Token` value under the cursor (for projecting its int/symbol payload).
(define (peek-tok [toks : (Array Token)] [cur : (Array i64)]) : Token
  (array-ref toks (cur-pos cur)))

(define (peek-spanned-token [toks : (Array SpannedToken)] [cur : (Array i64)]) : SpannedToken
  (array-ref toks (cur-pos cur)))

(define (peek-spanned-tag [toks : (Array SpannedToken)] [cur : (Array i64)]) : i64
  (token-tag (spanned-token-token (peek-spanned-token toks cur))))

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (Array i64)]) : unit
  (array-set! cur 0 (+ (cur-pos cur) 1)))

(define (read-prefix-tag? [t : i64]) : bool
  (or
    (= t (tag-quote))
    (or (= t (tag-backtick)) (or (= t (tag-comma)) (= t (tag-comma-at))))))

(define (read-prefix-symbol [t : i64]) : String
  (core/cond
    (= t (tag-quote))
    "quote"
    (= t (tag-backtick))
    "quasiquote"
    (= t (tag-comma))
    "unquote"
    (= t (tag-comma-at))
    "unquote-splicing"
    "quote"))

(define (read-prefix-form [name : String] [form : Sexpr]) : Sexpr
  (sexpr-cons (SSym name) (sexpr-cons form SNil)))

(define (read-prefix-spanned-form
  [name : String]
  [prefix-span : SourceSpan]
  [form : SpannedSexpr]) : SpannedSexpr
  (let
    [span : SourceSpan (merge-spans prefix-span (spanned-sexpr-span form))]
    (spanned-sexpr-cons
      (SpSSym name prefix-span)
      (spanned-sexpr-cons form (SpSNil (spanned-sexpr-span form)) span)
      span)))

;; --------------------------------------------------------------------------
;; The reader proper: `read-form` and `read-list`, mutually recursive.
;; --------------------------------------------------------------------------
;; read-form: read exactly one s-expression starting at the cursor and return
;; it, advancing the cursor past the tokens it consumed.
;;   TInt n  -> (SInt n)            an integer atom
;;   TFloat s -> (SFloat s)         a float atom carrying source text
;;   TSym s  -> (SSym s)            a symbol atom
;;   TStr s  -> (SStr s)            a string-literal atom (`"..."`, refs #128)
;;   TChar c -> (SChar c)           a character-literal atom (`#x'`, refs #333)
;;   TLParen -> read-list           consume '(' then read a list to its ')'
;;   TRParen -> error                a stray ')' with no opening '(' is malformed
;;   TEnd    -> error                end of stream where a form was expected
;; A grammar violation returns a recoverable `ErrSexpr String`; the compatibility
;; wrappers below still panic for callers that have not moved to `read-result`.
(define (read-form-spanned-result
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]) : ResultSpannedSexpr
  (let
    [st : SpannedToken (peek-spanned-token toks cur)]
    [tok : Token (spanned-token-token st)]
    [span : SourceSpan (spanned-token-span st)]
    [t : i64 (token-tag tok)]
    (core/cond
      (= t (tag-int))
      (let
        [v : i64 (token-int tok)]
        (begin
          (advance cur)
          (OkSpannedSexpr (SpSInt v span))))
      (= t (tag-float))
      (let
        [s : String (token-float tok)]
        (begin
          (advance cur)
          (OkSpannedSexpr (SpSFloat s span))))
      (= t (tag-sym))
      (let
        [s : String (token-sym tok)]
        (begin
          (advance cur)
          (OkSpannedSexpr (SpSSym s span))))
      (= t (tag-str))
      (let
        [s : String (token-str tok)]
        (begin
          (advance cur)
          (OkSpannedSexpr (SpSStr s span))))
      (= t (tag-char))
      (let
        [c : char (token-char tok)]
        (begin
          (advance cur)
          (OkSpannedSexpr (SpSChar c span))))
      (= t (tag-lparen))
      (begin
        (advance cur)
        (read-list-spanned-result toks cur span))
      (= t (tag-lbracket))
      (begin
        (advance cur)
        (read-bracket-list-spanned-result toks cur span))
      (read-prefix-tag? t)
      (let
        [name : String (read-prefix-symbol t)]
        (begin
          (advance cur)
          (match (read-form-spanned-result toks cur)
            [(OkSpannedSexpr form)
              (OkSpannedSexpr (read-prefix-spanned-form name span form))]
            [(ErrSpannedSexpr err) (ErrSpannedSexpr err)])))
      (= t (tag-rparen))
      (ErrSpannedSexpr (SourceError "reader: unexpected ')'" span))
      (= t (tag-rbracket))
      (ErrSpannedSexpr (SourceError "reader: unexpected ']'" span))
      (ErrSpannedSexpr (SourceError "reader: unexpected end of input" span)))))

(define (read-list-spanned-items-result
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]
  [open-span : SourceSpan]
  [close-tag : i64]
  [unterminated-message : String]) : ResultSpannedSexpr
  (let
    [st : SpannedToken (peek-spanned-token toks cur)]
    [span : SourceSpan (spanned-token-span st)]
    [t : i64 (token-tag (spanned-token-token st))]
    (if (= t close-tag)
      (begin
        (advance cur)
        (OkSpannedSexpr (SpSNil (merge-spans open-span span))))
      (if (= t (tag-end))
        (ErrSpannedSexpr (SourceError unterminated-message span))
        (match (read-form-spanned-result toks cur)
          [(OkSpannedSexpr head)
            (match (read-list-spanned-items-result
              toks
              cur
              open-span
              close-tag
              unterminated-message)
              [(OkSpannedSexpr tail)
                (OkSpannedSexpr
                  (spanned-sexpr-cons
                    head
                    tail
                    (merge-spans open-span (spanned-sexpr-span tail))))]
              [(ErrSpannedSexpr err) (ErrSpannedSexpr err)])]
          [(ErrSpannedSexpr err) (ErrSpannedSexpr err)])))))

(define (read-list-spanned-result
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]
  [open-span : SourceSpan]) : ResultSpannedSexpr
  (read-list-spanned-items-result
    toks
    cur
    open-span
    (tag-rparen)
    "reader: unterminated list (missing ')')"))

(define (read-bracket-list-spanned-result
  [toks : (Array SpannedToken)]
  [cur : (Array i64)]
  [open-span : SourceSpan]) : ResultSpannedSexpr
  (match (read-list-spanned-items-result
    toks
    cur
    open-span
    (tag-rbracket)
    "reader: unterminated list (missing ']')")
    [(OkSpannedSexpr items)
      (OkSpannedSexpr
        (spanned-sexpr-bracket-list items (spanned-sexpr-span items)))]
    [(ErrSpannedSexpr err) (ErrSpannedSexpr err)]))

(define (read-form-result [toks : (Array Token)] [cur : (Array i64)]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (core/cond
      (= t (tag-int))
      ;; An integer atom: project the literal out of the TInt and consume it.
      (let
        [v : i64 (token-int (peek-tok toks cur))]
        (begin
          (advance cur)
          (OkSexpr (SInt v))))
      (= t (tag-float))
      ;; A float atom: carry the lexeme text through the reader.
      (let
        [s : String (token-float (peek-tok toks cur))]
        (begin
          (advance cur)
          (OkSexpr (SFloat s))))
      (= t (tag-sym))
      ;; A symbol atom: project the lexeme out of the TSym and consume it.
      (let
        [s : String (token-sym (peek-tok toks cur))]
        (begin
          (advance cur)
          (OkSexpr (SSym s))))
      (= t (tag-str))
      ;; A string-literal atom: project the inner text out of the TStr
      ;; (via the imported `token-str` accessor, #128) and consume it.
      ;; `SStr` keeps it distinct from a same-character `SSym`.
      (let
        [s : String (token-str (peek-tok toks cur))]
        (begin
          (advance cur)
          (OkSexpr (SStr s))))
      (= t (tag-char))
      ;; A character-literal atom: project the char out of the
      ;; TChar token (via imported `token-char`) and consume it.
      (let
        [c : char (token-char (peek-tok toks cur))]
        (begin
          (advance cur)
          (OkSexpr (SChar c))))
      (= t (tag-lparen))
      ;; A list: consume '(' and read forms until the matching ')'.
      (begin
        (advance cur)
        (read-list-result toks cur))
      (= t (tag-lbracket))
      (begin
        (advance cur)
        (read-bracket-list-result toks cur))
      (read-prefix-tag? t)
      (let
        [name : String (read-prefix-symbol t)]
        (begin
          (advance cur)
          (match (read-form-result toks cur)
            [(OkSexpr form) (OkSexpr (read-prefix-form name form))]
            [(ErrSexpr message) (ErrSexpr message)])))
      (= t (tag-rparen))
      (ErrSexpr "reader: unexpected ')'")
      (= t (tag-rbracket))
      (ErrSexpr "reader: unexpected ']'")
      ;; tag-end (or anything else): premature end of stream.
      (ErrSexpr "reader: unexpected end of input"))))

;; read-list: the cursor is positioned just AFTER an opening '('. Read forms
;; until the matching ')', returning the proper list `(SCons f1 (SCons f2 ...
;; (SNil)))`. Built by right-recursion so the spine comes out in source order
;; with NO reversal: read the head form, then recurse to read the rest of the
;; list, and cons the two. The base case is the ')' that closes this list -
;; consume it and return `SNil`. Hitting `TEnd` before a ')' is an unterminated
;; list and returns `ErrSexpr`. Nesting is handled for free: a head form that is
;; itself a '(' re-enters `read-form-result` -> `read-list-result`, which reads
;; the inner list to ITS ')' and advances the shared cursor past it before this
;; level reads its next sibling.
(define (read-list-result-with-close
  [toks : (Array Token)]
  [cur : (Array i64)]
  [close-tag : i64]
  [unterminated-message : String]) : ResultSexpr
  (let
    [t : i64 (peek-tag toks cur)]
    (if (= t close-tag)
      ;; End of this list: consume the ')' and terminate the spine with SNil.
      (begin
        (advance cur)
        (OkSexpr SNil))
      (if (= t (tag-end))
        (ErrSexpr unterminated-message)
        ;; A list element: read the head form (which advances the cursor past
        ;; it, however deeply nested), then recurse for the tail and cons.
        (match (read-form-result toks cur)
          [(OkSexpr head)
            (match (read-list-result-with-close
              toks
              cur
              close-tag
              unterminated-message)
              [(OkSexpr tail) (OkSexpr (sexpr-cons head tail))]
              [(ErrSexpr message) (ErrSexpr message)])]
          [(ErrSexpr message) (ErrSexpr message)])))))

(define (read-list-result [toks : (Array Token)] [cur : (Array i64)]) : ResultSexpr
  (read-list-result-with-close
    toks
    cur
    (tag-rparen)
    "reader: unterminated list (missing ')')"))

(define (read-bracket-list-result [toks : (Array Token)] [cur : (Array i64)]) : ResultSexpr
  (read-list-result-with-close
    toks
    cur
    (tag-rbracket)
    "reader: unterminated list (missing ']')"))

(define (read-form [toks : (Array Token)] [cur : (Array i64)]) : Sexpr
  (match (read-form-result toks cur)
    [(OkSexpr form) form]
    [(ErrSexpr message)
      (begin
        (panic message)
        SNil)]))

(define (read-list [toks : (Array Token)] [cur : (Array i64)]) : Sexpr
  (match (read-list-result toks cur)
    [(OkSexpr list) list]
    [(ErrSexpr message)
      (begin
        (panic message)
        SNil)]))

;; read: the public entry point. Read a single top-level form from the front of
;; `toks` (a cursor starting at index 0) and return its `Sexpr` tree. (Trailing
;; tokens after the first form are ignored here, as a top-level `read` returns
;; one datum at a time.)
(define (read-result [toks : (Array Token)]) : ResultSexpr
  (let
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (read-form-result toks cur))))

(define (read-spanned-result [toks : (Array SpannedToken)]) : ResultSpannedSexpr
  (let
    [cur : (Array i64) (make-array i64 1)]
    (begin
      (array-set! cur 0 0)
      (read-form-spanned-result toks cur))))

(define (read-spanned [toks : (Array SpannedToken)]) : SpannedSexpr
  (match (read-spanned-result toks)
    [(OkSpannedSexpr form) form]
    [(ErrSpannedSexpr err)
      (begin
        (panic (source-error-message err))
        (SpSNil (source-error-span err)))]))

(define (read [toks : (Array Token)]) : Sexpr
  (match (read-result toks)
    [(OkSexpr form) form]
    [(ErrSexpr message)
      (begin
        (panic message)
        SNil)]))

;; --------------------------------------------------------------------------
;; An observable fold over the tree: sum every integer atom in the Sexpr.
;; --------------------------------------------------------------------------
;; A recursive tree walk with a `match` over `Sexpr`: an `SInt` contributes its
;; value, the atoms `SSym`/`SNil` contribute 0, and an `SCons` sums both its head
;; and tail. The bound recursive payloads (`h`/`t`) are boxes around child
;; enums, unwrapped before recursing into `sum-ints`. The result depends on the WHOLE
;; tree shape, so it is a faithful observation that the reader built it correctly.
(define (sum-ints [s : Sexpr]) : i64
  (match s
    [(SInt n) n]
    [(SSym _) 0]
    [(SStr _) 0]
    [(SChar _) 0]
    [(SFloat _) 0]
    [(SNil) 0]
    [(SCons h t) (+ (sum-ints (box-get h)) (sum-ints (box-get t)))]))

;; --------------------------------------------------------------------------
;; A second fold that OBSERVES the new `SStr` variant: count string atoms.
;; --------------------------------------------------------------------------
;; The same recursive tree walk shape as `sum-ints`, but it tallies the `SStr`
;; atoms the reader produced from `"..."` literals (#27/#128): an `SStr`
;; contributes 1, every other atom (`SInt`/`SSym`/`SNil`) contributes 0, and an
;; `SCons` sums both children. Because the count depends on the whole read tree,
;; it is a faithful observation that the reader consumed the lexer's `TStr` token
;; into an `SStr` rather than dropping it or folding it into an `SSym`.
(define (count-strs [s : Sexpr]) : i64
  (match s
    [(SInt _) 0]
    [(SSym _) 0]
    [(SStr _) 1]
    [(SChar _) 0]
    [(SFloat _) 0]
    [(SNil) 0]
    [(SCons h t) (+ (count-strs (box-get h)) (count-strs (box-get t)))]))

;; A third fold that OBSERVES the new `SChar` variant: count character atoms.
(define (count-chars [s : Sexpr]) : i64
  (match s
    [(SInt _) 0]
    [(SSym _) 0]
    [(SStr _) 0]
    [(SChar _) 1]
    [(SFloat _) 0]
    [(SNil) 0]
    [(SCons h t) (+ (count-chars (box-get h)) (count-chars (box-get t)))]))

;; A fourth fold that OBSERVES float atoms while preserving their text spelling.
(define (count-floats [s : Sexpr]) : i64
  (match s
    [(SInt _) 0]
    [(SSym _) 0]
    [(SStr _) 0]
    [(SChar _) 0]
    [(SFloat _) 1]
    [(SNil) 0]
    [(SCons h t) (+ (count-floats (box-get h)) (count-floats (box-get t)))]))

(define (sum-char-codes [s : Sexpr]) : i64
  (match s
    [(SInt _) 0]
    [(SSym _) 0]
    [(SStr _) 0]
    [(SChar c) (code c)]
    [(SFloat _) 0]
    [(SNil) 0]
    [(SCons h t) (+ (sum-char-codes (box-get h)) (sum-char-codes (box-get t)))]))

(define (reader-error-case-ok? [src : String] [message : String]) : bool
  (match (read-result (lex src))
    [(OkSexpr _) false]
    [(ErrSexpr got) (string-eq got message)]))

(define (reader-error-score) : i64
  (+
    (if (reader-error-case-ok? ")" "reader: unexpected ')'")
      1
      0)
    (+
      (if (reader-error-case-ok? "" "reader: unexpected end of input")
        1
        0)
      (if (reader-error-case-ok? "(" "reader: unterminated list (missing ')')")
        1
        0))))

(define (reader-nested-list-spans-ok?) : bool
  (let
    [tree : SpannedSexpr (read-spanned (lex-spanned "(a (b))"))]
    (match tree
      [(SpSCons _ tail outer-span)
        (match (box-get tail)
          [(SpSCons inner _ _)
            (and
              (span-eq? outer-span 1 1 1 7)
              (span-eq? (spanned-sexpr-span (box-get inner)) 1 4 1 6))]
          [_ false])]
      [_ false])))

(define (reader-spanned-error-ok?) : bool
  (match (read-spanned-result (lex-spanned "("))
    [(ErrSpannedSexpr err)
      (and
        (string-eq
          (source-error-message err)
          "reader: unterminated list (missing ')')")
        (span-eq? (source-error-span err) 1 2 1 2))]
    [(OkSpannedSexpr _) false]))

(define (reader-prefix-quote-spans-ok?) : bool
  (match (read-spanned (lex-spanned "`x"))
    [(SpSCons head tail outer-span)
      (match (box-get head)
        [(SpSSym name prefix-span)
          (and
            (string-eq name "quasiquote")
            (and
              (span-eq? prefix-span 1 1 1 1)
              (and
                (span-eq? outer-span 1 1 1 2)
                (match (box-get tail)
                  [(SpSCons form _ _)
                    (span-eq? (spanned-sexpr-span (box-get form)) 1 2 1 2)]
                  [_ false]))))]
        [_ false])]
    [_ false]))

(define (reader-bracket-list-boxed-ok?) : bool
  (match (read-spanned (lex-spanned "[1 2]"))
    [(SpSBracketList items span)
      (and
        (span-eq? span 1 1 1 5)
        (= (sum-ints (spanned-sexpr-form (box-get items))) 3))]
    [_ false]))

;; main: lex a real nested s-expression that mixes integer, float, string, and
;; character atoms, READ it into the `Sexpr` cons tree, and fold that tree. The
;; source `(greet "hi" #x' 7 1.5 (msg "yo" #\space' #\newline' 35 #\n'))` lexes to
;;   (  greet  "hi"  #x'  7  1.5  (  msg  "yo"  #\space'  #\newline'  35  #\n'  )  )  End
;; and reads into a recursive tree containing two string atoms, one float atom, four character
;; atoms, and integer atoms summing to 42. The decoded character code sum is 172,
;; so the successful read contributes 42 + 2 + 4 + 1 + 10 = 59 when the reader
;; preserves char values. The recoverable error probes add 3 more.
(define (main) : i64
  (let
    [tree : Sexpr
      (read
        (lex
          "(greet \"hi\" #x' 7 1.5 (msg \"yo\" #\\space' #\\newline' 35 #\\n'))"))]
    (+
      (sum-ints tree)
      (+
        (count-strs tree)
        (+
          (count-chars tree)
          (+
            (count-floats tree)
            (+
              (if (= (sum-char-codes tree) 172)
                10
                0)
              (if (and
                (reader-nested-list-spans-ok?)
                (and
                  (reader-spanned-error-ok?)
                  (and
                    (reader-prefix-quote-spans-ok?)
                    (reader-bracket-list-boxed-ok?))))
                (reader-error-score)
                0))))))))