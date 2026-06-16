;; read.tl - The s-expression READER for TypeLisp's own syntax, factored out
;; as a `main`-less, importable module (refs #27/#44).
;;
;; --------------------------------------------------------------------------
;; Why this module exists (the module signal for reusable reader code, refs
;; #44/#81).
;; --------------------------------------------------------------------------
;; `reader.tl` is the *demo* program for the s-expression reader: it carries a
;; `main` that reads a sample and folds the resulting tree with `sum-ints`.
;; Reusable frontend modules need the reader's `read : (-> (Array Token) Sexpr)`
;; and the `Sexpr` AST it builds without inheriting that demo `main`.
;;
;; The legacy stage0 module loader (#44) is whole-program: it concatenates every
;; imported module's declarations into a single program, then runs the unchanged
;; `typecheck -> lower -> codegen` pipeline. So two modules that both declare a
;; `main` and are loaded together produce a duplicate `main` symbol - the known
;; legacy limitation. The selfhost namespace model specified in SPEC.md replaces
;; this flat import behavior with qualified module identities. Importing
;; `reader.tl` (which HAS a `main`) into another command driver that also needs
;; a `main` would clash today.
;;
;; The fix is this `main`-less module: it holds the reader's cursor helpers, the
;; mutually recursive `read-form` / `read-list`, the public `read` entry, AND the
;; `Sexpr` AST definition, `(import)`s the shared `main`-less `lex.tl` (which
;; transitively imports the `main`-less `token.tl`), and declares NO `main`.
;; Command drivers and compiler modules can import it and still produce a
;; concatenated program with exactly one `main`. `reader.tl` stays as the
;; reader's standalone demo. This mirrors how `lex.tl` was factored from the
;; `main`-bearing `lexer.tl`: a `main`-less module is the unit of reuse, a
;; `main`-bearing file is a runnable demo.
;; The shared lexer: the public `lex : (-> String (Array Token))`, factored into
;; a `main`-less module. `lex.tl` in turn imports the `main`-less
;; `token.tl` token model, so this single import transitively pulls in BOTH
;; the `lex` entry and the `Token` enum + token accessors/tag constants.
;; Resolved relative to this file, so it finds the co-located `lex.tl`.
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
;; reader builds this tree; importers can walk it with `match`-based recursion.
;; `SStr` carries the inner text of a `"..."` string-literal datum: the reader
;; consumes the lexer's `TStr` token (#128) into it, so a quoted string reads as a
;; distinct atom rather than being conflated with a `SSym` of the same characters.
;; `SChar` carries a `#x'` / `#\x'` character-literal datum (#333), likewise
;; keeping chars distinct from symbols, ints, and strings. `SStr` and `SChar`
;; are appended last so the existing variants keep their stable ordering for
;; every importer.
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
  (SpSCons i64 i64 SourceSpan)
  (SpSStr String SourceSpan)
  (SpSChar char SourceSpan)
  (SpSFloat String SourceSpan)
  (SpSBracketList i64 SourceSpan))

(defenum ResultSpannedSexpr
  (OkSpannedSexpr SpannedSexpr)
  (ErrSpannedSexpr SourceError))

;; --- flat SpannedSexpr node pool (mirrors the AstExpr flat pool, #2294) ---
;; SpSCons / SpSBracketList children are i64 ids into this pool instead of
;; (box ...). Two plain globals (array + count), NOT a struct, to avoid the
;; opt2 hot-path-inline miscompile seen on the AstExpr pool. The spanned tree
;; is transient (consumed into AstExpr, spans copied out by value, then dead),
;; so the pool is reset per program parse (see compiler_parse_core.tl).
(define sp-node-pool-slots : (Array SpannedSexpr)
  (make-array SpannedSexpr 262144))
(define sp-node-pool-count : i64
  0)

(define (sp-node-pool-len) : i64
  sp-node-pool-count)

;; Grow is a safety net only. The spanned pool is reset per program parse AND
;; truncated per top-level form (compiler_parse_core.tl), so live size stays
;; well under the initial capacity and grow! never fires on real inputs. That
;; matters because growing reassigns the global mid-push and the opt2 optimizer
;; can cache the pre-grow array across the grow! call (the same CSE-across-call
;; hazard the AST pool sidesteps by pre-sizing). Keeping grow dead avoids it.
(define (sp-node-pool-grow!) : unit
  (let
    [old-slots : (Array SpannedSexpr) sp-node-pool-slots]
    [old-cap : i64 (array-length old-slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1024
        (* old-cap 2))]
    [new-slots : (Array SpannedSexpr) (make-array SpannedSexpr new-cap)]
    [len : i64 sp-node-pool-count]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! new-slots i (array-ref old-slots i))
          (set! i (+ i 1))))
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

(define (sexpr-cons [head : Sexpr] [tail : Sexpr]) : Sexpr
  (SCons (box head) (box tail)))

(define (spanned-sexpr-cons
  [head : SpannedSexpr]
  [tail : SpannedSexpr]
  [span : SourceSpan]) : SpannedSexpr
  (SpSCons (sp-node-push head) (sp-node-push tail) span))

(define (spanned-sexpr-bracket-list [items : SpannedSexpr] [span : SourceSpan]) : SpannedSexpr
  (SpSBracketList (sp-node-push items) span))

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
        (spanned-sexpr-form (sp-node-get head))
        (spanned-sexpr-form (sp-node-get tail)))]
    [(SpSStr text _) (SStr text)]
    [(SpSChar c _) (SChar c)]
    [(SpSFloat text _) (SFloat text)]
    [(SpSBracketList items _) (spanned-sexpr-form (sp-node-get items))]))

;; --------------------------------------------------------------------------
;; The reader cursor: a single mutable index into the `(Array Token)`.
;; --------------------------------------------------------------------------
;; A TypeLisp function returns a single value, but the reader must both *return
;; an `Sexpr`* and *advance past the tokens it consumed*. So the position is an
;; out-param: a single-cell `(Array i64)` (`cur`) holding the index of the token
;; under the cursor. Because arrays are heap references, a mutation through `cur`
;; is visible to the caller across the recursive `read-form` / `read-list` calls.
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
    (= t (tag-backtick))
    (= t (tag-comma))
    (= t (tag-comma-at))))

(define (read-prefix-symbol [t : i64]) : String
  (if (= t (tag-quote))
    "quote"
    (if (= t (tag-backtick))
      "quasiquote"
      (if (= t (tag-comma))
        "unquote"
        (if (= t (tag-comma-at))
          "unquote-splicing"
          "quote")))))

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
    (if (= t (tag-int))
      (let
        [v : i64 (token-int tok)]
        (begin
          (advance cur)
          (OkSpannedSexpr (SpSInt v span))))
      (if (= t (tag-float))
        (let
          [s : String (token-float tok)]
          (begin
            (advance cur)
            (OkSpannedSexpr (SpSFloat s span))))
        (if (= t (tag-sym))
          (let
            [s : String (token-sym tok)]
            (begin
              (advance cur)
              (OkSpannedSexpr (SpSSym s span))))
          (if (= t (tag-str))
            (let
              [s : String (token-str tok)]
              (begin
                (advance cur)
                (OkSpannedSexpr (SpSStr s span))))
            (if (= t (tag-char))
              (let
                [c : char (token-char tok)]
                (begin
                  (advance cur)
                  (OkSpannedSexpr (SpSChar c span))))
              (if (= t (tag-lparen))
                (begin
                  (advance cur)
                  (read-list-spanned-result toks cur span))
                (if (= t (tag-lbracket))
                  (begin
                    (advance cur)
                    (read-bracket-list-spanned-result toks cur span))
                  (if (read-prefix-tag? t)
                    (let
                      [name : String (read-prefix-symbol t)]
                      (begin
                        (advance cur)
                        (match (read-form-spanned-result toks cur)
                          [(OkSpannedSexpr form)
                            (OkSpannedSexpr
                              (read-prefix-spanned-form name span form))]
                          [(ErrSpannedSexpr err) (ErrSpannedSexpr err)])))
                    (if (= t (tag-rparen))
                      (ErrSpannedSexpr
                        (SourceError "reader: unexpected ')'" span))
                      (if (= t (tag-rbracket))
                        (ErrSpannedSexpr
                          (SourceError "reader: unexpected ']'" span))
                        (ErrSpannedSexpr
                          (SourceError "reader: unexpected end of input" span))))))))))))))

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
    (if (= t (tag-int))
      (let
        [v : i64 (token-int (peek-tok toks cur))]
        (begin
          (advance cur)
          (OkSexpr (SInt v))))
      (if (= t (tag-float))
        (let
          [s : String (token-float (peek-tok toks cur))]
          (begin
            (advance cur)
            (OkSexpr (SFloat s))))
        (if (= t (tag-sym))
          (let
            [s : String (token-sym (peek-tok toks cur))]
            (begin
              (advance cur)
              (OkSexpr (SSym s))))
          (if (= t (tag-str))
            (let
              [s : String (token-str (peek-tok toks cur))]
              (begin
                (advance cur)
                (OkSexpr (SStr s))))
            (if (= t (tag-char))
              (let
                [c : char (token-char (peek-tok toks cur))]
                (begin
                  (advance cur)
                  (OkSexpr (SChar c))))
              (if (= t (tag-lparen))
                (begin
                  (advance cur)
                  (read-list-result toks cur))
                (if (= t (tag-lbracket))
                  (begin
                    (advance cur)
                    (read-bracket-list-result toks cur))
                  (if (read-prefix-tag? t)
                    (let
                      [name : String (read-prefix-symbol t)]
                      (begin
                        (advance cur)
                        (match (read-form-result toks cur)
                          [(OkSexpr form)
                            (OkSexpr (read-prefix-form name form))]
                          [(ErrSexpr message) (ErrSexpr message)])))
                    (if (= t (tag-rparen))
                      (ErrSexpr "reader: unexpected ')'")
                      (if (= t (tag-rbracket))
                        (ErrSexpr "reader: unexpected ']'")
                        (ErrSexpr "reader: unexpected end of input")))))))))))))

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