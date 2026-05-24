;; token.tl - The shared token model for the TypeLisp calculator front end,

;; factored out as a `main`-less, importable module (refs #27/#44).

;;

;; This is the multi-file-organization slice of the self-hosting milestone: the

;; `Token` type and the accessors that operate on it are lifted out of the

;; combined `calc.tl` into a module that defines NO `main` and NO lexer/parser

;; logic. `calc.tl` `(import "token.tl")`s it and uses the shared type, so the

;; lexer (which constructs `Token` values) and the parser (which classifies them

;; through `token-tag` / projects operands with `token-int`) agree on one

;; canonical definition rather than each carrying its own copy.

;;

;; --------------------------------------------------------------------------

;; Why this composes cleanly across the import boundary (the key #44/#81 signal).

;; --------------------------------------------------------------------------

;; The module loader (#44) is whole-program: it concatenates every imported

;; module's declarations into a single `Program`, imported-before-importer, then

;; runs the unchanged `typecheck -> lower -> codegen` pipeline. Consequently:

;;

;;   - The imported `defenum Token` defines ONE nominal type. The importer's

;;     `Token` parameters/locals refer to that same type - there is no

;;     per-module enum identity, so a `Token` built in the importer's lexer and a

;;     `Token` matched by an imported accessor are the same type. No

;;     cross-module nominal-identity gap surfaces.

;;   - The constructors (`TInt`, `TPlus`, ... `TEnd`) and `match` arms defined

;;     here are usable from the importer exactly as if defined locally.

;;   - Because this module declares no `main` (and `calc.tl` no longer declares

;;     its own `Token`/`token-tag`/`token-int`), concatenation yields exactly one

;;     `main` and one of each accessor - no duplicate-symbol clash.

;; The token kinds the calculator surface needs: integer literals, the four

;; binary operators, parentheses, and an end-of-stream sentinel.

(defenum Token
  (TInt i64)
  (TPlus)
  (TMinus)
  (TStar)
  (TSlash)
  (TLParen)
  (TRParen)
  (TEnd))

;; Numeric tag for a token kind: the parser's cursor classifies the token under

;; it by tag. Exercises `match` over every Token variant - and proves an

;; imported `defenum`'s `match` works across the import boundary.

(define (token-tag [t : Token]) : i64
  (match t
    [(TInt _) 1]
    [(TPlus) 2]
    [(TMinus) 3]
    [(TStar) 4]
    [(TSlash) 5]
    [(TLParen) 6]
    [(TRParen) 7]
    [(TEnd) 8]))

;; Integer payload of a TInt token (0 for any other kind): projects the operand

;; back out of the enum, the way the parser reads a literal.

(define (token-int [t : Token]) : i64
  (match t
    [(TInt v) v]
    [(TPlus) 0]
    [(TMinus) 0]
    [(TStar) 0]
    [(TSlash) 0]
    [(TLParen) 0]
    [(TRParen) 0]
    [(TEnd) 0]))

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