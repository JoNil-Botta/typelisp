;; token.tl - The shared token model for the TypeLisp calculator front end,
;; factored out as a `main`-less, importable module (refs #27/#44).
;;
;; This is the multi-file-organization slice of the self-hosting milestone: the
;; `Token` type and the accessors that operate on it are lifted out of the
;; combined `calc.tl` into a module that defines NO `main` and NO lexer/parser
;; logic. `calc.tl` `(import token)`s it and uses qualified `token.Token`,
;; `token.token-tag`, and `token.token-int` references, so the lexer and parser
;; agree on one canonical definition rather than each carrying its own copy.
;;
;; --------------------------------------------------------------------------
;; Why this composes cleanly across the import boundary (the key #44/#81 signal).
;; --------------------------------------------------------------------------
;; The selfhost namespace model specified in SPEC.md uses qualified module
;; identities. Consequently:
;;
;;   - The imported `defenum Token` defines one nominal type. The importer's
;;     `token.Token` parameters/locals refer to that same type, so a token built
;;     in the importer's lexer and a token matched by an imported accessor are
;;     the same type.
;;   - The constructors (`token.Token.Int`, `token.Token.Plus`, ...
;;     `token.Token.End`) and accessors are usable through the module alias.
;;   - Because this module declares no `main` (and `calc.tl` no longer declares
;;     its own token model), there is exactly one entry point and one token API.
;; The token kinds the calculator surface needs: integer literals, the four
;; binary operators, parentheses, and an end-of-stream sentinel.
(defenum Token
  (Int i64)
  (Plus)
  (Minus)
  (Star)
  (Slash)
  (LParen)
  (RParen)
  (End))

;; Numeric tag for a token kind: the parser's cursor classifies the token under
;; it by tag. Exercises `match` over every Token variant - and proves an
;; imported `defenum`'s `match` works across the import boundary.
(define (token-tag [t : Token]) : i64
  (match t
    [(Token.Int _) 1]
    [(Token.Plus) 2]
    [(Token.Minus) 3]
    [(Token.Star) 4]
    [(Token.Slash) 5]
    [(Token.LParen) 6]
    [(Token.RParen) 7]
    [(Token.End) 8]))

;; Integer payload of `Token.Int` (0 for any other kind): projects the operand
;; back out of the enum, the way the parser reads a literal.
(define (token-int [t : Token]) : i64
  (match t
    [(Token.Int v) v]
    [(Token.Plus) 0]
    [(Token.Minus) 0]
    [(Token.Star) 0]
    [(Token.Slash) 0]
    [(Token.LParen) 0]
    [(Token.RParen) 0]
    [(Token.End) 0]))

;; ---- Token-kind tag constants (kept in sync with `token-tag`). ----
;; The parser compares a token's tag against these to drive its descent.
(define (tag-int) : i64
  1)

(define (tag-plus) : i64
  2)

(define (tag-minus) : i64
  3)

(define (tag-star) : i64
  4)

(define (tag-slash) : i64
  5)

(define (tag-lparen) : i64
  6)

(define (tag-rparen) : i64
  7)

(define (tag-end) : i64
  8)