;; tl_reader.tl - The s-expression READER for TypeLisp's own syntax: the
;; canonical Lisp reader, written in TypeLisp itself. The second component of
;; TypeLisp's self-hosting compiler front end (#27), following the tokenizer.
;;
;; Where the lexer (`tl_lex.tl`) turns a source String into a flat
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
;; The reader does NOT re-derive tokenization. It `(import "tl_lex.tl")`s the
;; lexer's public `lex : (-> String (Array Token))`, factored into a `main`-less
;; module precisely so it can be shared. `tl_lex.tl` in turn imports the
;; `main`-less `tl_token.tl` token model, so this single import transitively
;; pulls in BOTH the `lex` entry and the `Token` enum + `token-tag` /
;; `token-int` / `token-sym` accessors + tag constants.
;;
;; The module loader (#44) is whole-program: it concatenates every reachable
;; module's declarations (post-order DFS: imported-before-importer), then runs
;; the unchanged pipeline. So the load order is `tl_token.tl`, then `tl_lex.tl`,
;; then this file. Crucially, NONE of the imported modules declares a `main` -
;; only this reader does - so the concatenated program has exactly one `main`
;; and there is no duplicate-symbol clash. (Importing the `main`-bearing
;; `tl_lexer.tl` demo instead would have clashed; that is why the reusable lexer
;; lives in the `main`-less `tl_lex.tl`.) The imported `defenum Token` is ONE
;; nominal type, so the `(array-ref toks i)` values this reader classifies are
;; the very `Token` values the imported `lex` constructed - the enum, its
;; constructors, and the accessors' `match` arms all carry across the boundary.
(import "tl_lex.tl")

;; --------------------------------------------------------------------------
;; The Sexpr AST: cons cells, the way Lisp represents read source (refs #13/#27).
;; --------------------------------------------------------------------------
;; An s-expression is an atom (an integer or a symbol), the empty list, or a cons
;; cell pairing a head s-expression with a tail s-expression. A *proper list*
;; `(a b c)` is the right-nested spine `(SCons a (SCons b (SCons c (SNil))))`,
;; terminated by `SNil` - exactly the cons-cell encoding of a list in any Lisp.
;; `SCons` carries two `Sexpr` children; recursive enum payloads (#111) make each
;; child an 8-byte heap pointer, so the layout is finite and every constructed
;; node that escapes via a return is heap-promoted. The reader builds this tree;
;; a `match`-based fold walks it.
(defenum Sexpr
  (SInt i64)
  (SSym String)
  (SNil)
  (SCons Sexpr Sexpr))

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

;; Consume the current token: advance the cursor by one.
(define (advance [cur : (Array i64)]) : unit
  (array-set! cur 0 (+ (cur-pos cur) 1)))

;; --------------------------------------------------------------------------
;; The reader proper: `read-form` and `read-list`, mutually recursive.
;; --------------------------------------------------------------------------

;; read-form: read exactly one s-expression starting at the cursor and return
;; it, advancing the cursor past the tokens it consumed.
;;   TInt n  -> (SInt n)            an integer atom
;;   TSym s  -> (SSym s)            a symbol atom
;;   TLParen -> read-list           consume '(' then read a list to its ')'
;;   TRParen -> error                a stray ')' with no opening '(' is malformed
;;   TEnd    -> error                end of stream where a form was expected
;; A grammar violation aborts via the `panic` builtin (#45), exactly how a real
;; reader reports malformed input.
(define (read-form [toks : (Array Token)] [cur : (Array i64)]) : Sexpr
  (let ([t : i64 (peek-tag toks cur)])
    (if (= t (tag-int))
        ;; An integer atom: project the literal out of the TInt and consume it.
        (let ([v : i64 (token-int (peek-tok toks cur))])
          (begin
            (advance cur)
            (SInt v)))
        (if (= t (tag-sym))
            ;; A symbol atom: project the lexeme out of the TSym and consume it.
            (let ([s : String (token-sym (peek-tok toks cur))])
              (begin
                (advance cur)
                (SSym s)))
            (if (= t (tag-lparen))
                ;; A list: consume '(' and read forms until the matching ')'.
                (begin
                  (advance cur)
                  (read-list toks cur))
                (if (= t (tag-rparen))
                    (begin
                      (panic "reader: unexpected ')'")
                      ;; Dead code: `panic` never returns, but the `if` needs a Sexpr.
                      SNil)
                    ;; tag-end (or anything else): premature end of stream.
                    (begin
                      (panic "reader: unexpected end of input")
                      SNil)))))))

;; read-list: the cursor is positioned just AFTER an opening '('. Read forms
;; until the matching ')', returning the proper list `(SCons f1 (SCons f2 ...
;; (SNil)))`. Built by right-recursion so the spine comes out in source order
;; with NO reversal: read the head form, then recurse to read the rest of the
;; list, and cons the two. The base case is the ')' that closes this list -
;; consume it and return `SNil`. Hitting `TEnd` before a ')' is an unterminated
;; list and aborts via `panic`. Nesting is handled for free: a head form that is
;; itself a '(' re-enters `read-form` -> `read-list`, which reads the inner list
;; to ITS ')' and advances the shared cursor past it before this level reads its
;; next sibling.
(define (read-list [toks : (Array Token)] [cur : (Array i64)]) : Sexpr
  (let ([t : i64 (peek-tag toks cur)])
    (if (= t (tag-rparen))
        ;; End of this list: consume the ')' and terminate the spine with SNil.
        (begin
          (advance cur)
          SNil)
        (if (= t (tag-end))
            (begin
              (panic "reader: unterminated list (missing ')')")
              SNil)
            ;; A list element: read the head form (which advances the cursor past
            ;; it, however deeply nested), then recurse for the tail and cons.
            (let ([head : Sexpr (read-form toks cur)])
              (SCons head (read-list toks cur)))))))

;; read: the public entry point. Read a single top-level form from the front of
;; `toks` (a cursor starting at index 0) and return its `Sexpr` tree. (Trailing
;; tokens after the first form are ignored here, as a top-level `read` returns
;; one datum at a time.)
(define (read [toks : (Array Token)]) : Sexpr
  (let ([cur : (Array i64) (make-array i64 1)])
    (begin
      (array-set! cur 0 0)
      (read-form toks cur))))

;; --------------------------------------------------------------------------
;; An observable fold over the tree: sum every integer atom in the Sexpr.
;; --------------------------------------------------------------------------
;; A recursive tree walk with a `match` over `Sexpr`: an `SInt` contributes its
;; value, the atoms `SSym`/`SNil` contribute 0, and an `SCons` sums both its head
;; and tail. The bound recursive payloads (`h`/`t`) are pointers to the child
;; enums, passed straight back into `sum-ints`. The result depends on the WHOLE
;; tree shape, so it is a faithful observation that the reader built it correctly.
(define (sum-ints [s : Sexpr]) : i64
  (match s
    [(SInt n) n]
    [(SSym _) 0]
    [(SNil) 0]
    [(SCons h t) (+ (sum-ints h) (sum-ints t))]))

;; main: lex a real nested s-expression, READ it into the `Sexpr` cons tree, and
;; fold that tree. The source "(+ 1 (* 2 3))" lexes to
;;   (  +  1  (  *  2  3  )  )  End
;; and reads into the tree
;;   (SCons (SSym "+")
;;     (SCons (SInt 1)
;;       (SCons (SCons (SSym "*") (SCons (SInt 2) (SCons (SInt 3) (SNil))))
;;         (SNil))))
;; whose integer atoms are 1, 2, 3. `sum-ints` therefore returns 1 + 2 + 3 = 6,
;; an observable result an execution test asserts as the exit code - and it
;; depends on the reader correctly handling the nested inner list.
(define (main) : i64
  (sum-ints (read (lex "(+ 1 (* 2 3))"))))
