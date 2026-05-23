;; token.tl - The token model for a lexer of TypeLisp's OWN s-expression
;; syntax, factored out as a `main`-less, importable module (refs #27/#44).
;;
;; This is the token vocabulary for the *self-hosting front end proper*: not the
;; arithmetic-calculator surface (`+ - * /` as distinct operator tokens, in
;; `token.tl`/`calc.tl`), but the surface TypeLisp source is actually written in
;; - balanced parentheses, integer literals, and *symbols*. In an s-expression
;; language an operator like `+`, a comparison like `<=`, a keyword like
;; `define`, and a name like `string->int` are ALL one token kind: a symbol. So
;; the kinds collapse to parens / int / symbol / end-of-stream, and the lexer's
;; job is to slice each symbol/int lexeme out of the source rather than to
;; recognise a fixed operator alphabet.
;;
;; --------------------------------------------------------------------------
;; Why this is a separate, importable module (the #44/#81 signal).
;; --------------------------------------------------------------------------
;; The module loader (#44) is whole-program: it concatenates every imported
;; module's declarations into a single `Program`, imported-before-importer, then
;; runs the unchanged `typecheck -> lower -> codegen` pipeline. So:
;;
;;   - The imported `defenum Token` defines ONE nominal type. The importer's
;;     `Token` parameters/locals and the `Token` values its lexer constructs all
;;     refer to that same type - there is no per-module enum identity.
;;   - The constructors (`TLParen`, `TInt`, `TSym`, ...) and the accessors'
;;     `match` arms defined here are usable from the importer as if local.
;;   - Because this module declares no `main`, concatenation yields exactly one
;;     `main` (the importer's) - no duplicate-symbol clash.

;; The token kinds TypeLisp's s-expression surface needs: an opening paren, a
;; closing paren, an integer literal, a symbol (any operator / keyword / name -
;; carries the sliced lexeme text), a string literal (`"..."`, carries the
;; sliced inner text), and an end-of-stream sentinel. `TStr` is appended last so
;; the existing variants/tags keep their stable ordering for every importer.
(defenum Token
  (TLParen)
  (TRParen)
  (TInt i64)
  (TSym String)
  (TEnd)
  (TStr String))

;; Numeric tag for a token kind: a parser's cursor classifies the token under it
;; by tag. Exercises `match` over every Token variant, including the
;; String-payload `TSym` and the i64-payload `TInt`.
(define (token-tag [t : Token]) : i64
  (match t
    [(TLParen) 1]
    [(TRParen) 2]
    [(TInt _) 3]
    [(TSym _) 4]
    [(TEnd) 5]
    [(TStr _) 6]))

;; Integer payload of a TInt token (0 for any other kind): projects the literal
;; value back out of the enum, the way a parser reads a numeric literal.
(define (token-int [t : Token]) : i64
  (match t
    [(TLParen) 0]
    [(TRParen) 0]
    [(TInt v) v]
    [(TSym _) 0]
    [(TEnd) 0]
    [(TStr _) 0]))

;; Symbol text of a TSym token (the empty string for any other kind): projects
;; the sliced lexeme back out of the enum, the way a parser reads a symbol/name.
(define (token-sym [t : Token]) : String
  (match t
    [(TLParen) ""]
    [(TRParen) ""]
    [(TInt _) ""]
    [(TSym s) s]
    [(TEnd) ""]
    [(TStr _) ""]))

;; String text of a TStr token (the empty string for any other kind): projects
;; the sliced inner text of a `"..."` literal back out of the enum, the way a
;; parser reads a string-literal datum. Distinct from `token-sym` so a `TStr`
;; and a `TSym` with the same characters stay distinguishable.
(define (token-str [t : Token]) : String
  (match t
    [(TLParen) ""]
    [(TRParen) ""]
    [(TInt _) ""]
    [(TSym _) ""]
    [(TEnd) ""]
    [(TStr s) s]))

;; ---- Token-kind tag constants (kept in sync with `token-tag`). ----
;; A parser compares a token's tag against these to drive its descent.
(define (tag-lparen) : i64 1)
(define (tag-rparen) : i64 2)
(define (tag-int) : i64 3)
(define (tag-sym) : i64 4)
(define (tag-end) : i64 5)
(define (tag-str) : i64 6)
