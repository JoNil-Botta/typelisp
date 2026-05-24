;; token.tl - The token model for a lexer of TypeLisp's OWN s-expression

;; syntax, factored out as a `main`-less, importable module (refs #27/#44).

;;

;; This is the token vocabulary for the *self-hosting front end proper*: not the

;; arithmetic-calculator surface (`+ - * /` as distinct operator tokens, in

;; `token.tl`/`calc.tl`), but the surface TypeLisp source is actually written in

;; - balanced parentheses, integer/float/char/string literals, and *symbols*. In an s-expression

;; language an operator like `+`, a comparison like `<=`, a keyword like

;; `define`, and a name like `string->int` are ALL one token kind: a symbol. So

;; the kinds collapse to parens / int / float / symbol / end-of-stream, and the lexer's

;; job is to slice each symbol/int/float lexeme out of the source rather than to

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

;; closing paren, an integer or float literal, a symbol (any operator / keyword / name -

;; carries the sliced lexeme text), a string literal (`"..."`, carries the

;; sliced inner text), a character literal (`#x'` / `#\x'`, carries the char),

;; and an end-of-stream sentinel. `TStr`, `TChar`, and `TFloat` are appended last so the

;; existing variants/tags keep their stable ordering for every importer.

(defenum Token
  (TLParen)
  (TRParen)
  (TInt i64)
  (TSym String)
  (TEnd)
  (TStr String)
  (TChar char)
  (TFloat String)
  (TLBracket)
  (TRBracket))

;; Source locations are 1-based line/column pairs. The end position is

;; exclusive, so a one-character token at line 1 column 1 spans 1:1 -> 1:2.

(defstruct SourceSpan
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defstruct SourceError
  (message String)
  (span SourceSpan))

(define (span-start-line [span : SourceSpan]) : i64
  (struct-get span start-line))

(define (span-start-col [span : SourceSpan]) : i64
  (struct-get span start-col))

(define (span-end-line [span : SourceSpan]) : i64
  (struct-get span end-line))

(define (span-end-col [span : SourceSpan]) : i64
  (struct-get span end-col))

(define (span-eq?
  [span : SourceSpan]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (and
    (= (span-start-line span) start-line)
    (and
      (= (span-start-col span) start-col)
      (and (= (span-end-line span) end-line) (= (span-end-col span) end-col)))))

(define (source-error-message [err : SourceError]) : String
  (struct-get err message))

(define (source-error-span [err : SourceError]) : SourceSpan
  (struct-get err span))

(define (merge-spans [start : SourceSpan] [end : SourceSpan]) : SourceSpan
  (SourceSpan
    (span-start-line start)
    (span-start-col start)
    (span-end-line end)
    (span-end-col end)))

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
    [(TStr _) 6]
    [(TChar _) 7]
    [(TFloat _) 8]
    [(TLBracket) 9]
    [(TRBracket) 10]))

;; Integer payload of a TInt token (0 for any other kind): projects the literal

;; value back out of the enum, the way a parser reads a numeric literal.

(define (token-int [t : Token]) : i64
  (match t
    [(TLParen) 0]
    [(TRParen) 0]
    [(TInt v) v]
    [(TSym _) 0]
    [(TEnd) 0]
    [(TStr _) 0]
    [(TChar _) 0]
    [(TFloat _) 0]
    [(TLBracket) 0]
    [(TRBracket) 0]))

;; Symbol text of a TSym token (the empty string for any other kind): projects

;; the sliced lexeme back out of the enum, the way a parser reads a symbol/name.

(define (token-sym [t : Token]) : String
  (match t
    [(TLParen) ""]
    [(TRParen) ""]
    [(TInt _) ""]
    [(TSym s) s]
    [(TEnd) ""]
    [(TStr _) ""]
    [(TChar _) ""]
    [(TFloat _) ""]
    [(TLBracket) ""]
    [(TRBracket) ""]))

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
    [(TStr s) s]
    [(TChar _) ""]
    [(TFloat _) ""]
    [(TLBracket) ""]
    [(TRBracket) ""]))

;; Float literal text of a TFloat token (the empty string for any other kind):

;; the selfhost frontend carries source spelling until backend emission, so it

;; does not need a string->f64 primitive.

(define (token-float [t : Token]) : String
  (match t
    [(TLParen) ""]
    [(TRParen) ""]
    [(TInt _) ""]
    [(TSym _) ""]
    [(TEnd) ""]
    [(TStr _) ""]
    [(TChar _) ""]
    [(TFloat s) s]
    [(TLBracket) ""]
    [(TRBracket) ""]))

;; Character payload of a TChar token (NUL for any other kind): projects the

;; read character back out of the enum while keeping char atoms distinct from

;; symbols, ints, and strings.

(define (token-char [t : Token]) : char
  (match t
    [(TLParen) #\nul']
    [(TRParen) #\nul']
    [(TInt _) #\nul']
    [(TSym _) #\nul']
    [(TEnd) #\nul']
    [(TStr _) #\nul']
    [(TChar c) c]
    [(TFloat _) #\nul']
    [(TLBracket) #\nul']
    [(TRBracket) #\nul']))

;; A token paired with the 1-based source line and column where its lexeme

;; begins (#599). The reader/parser recover positions from these so later

;; diagnostics can point at the originating source location. `TEnd` carries the

;; position one past the last character. This is additive: the plain `Token`

;; stream and its accessors are unchanged, so existing callers keep working.

(defenum SpannedToken
  (SpannedToken Token i64 i64))

(define (spanned-token-tok [s : SpannedToken]) : Token
  (match s
    [(SpannedToken t _ _) t]))

(define (spanned-token-line [s : SpannedToken]) : i64
  (match s
    [(SpannedToken _ line _) line]))

(define (spanned-token-col [s : SpannedToken]) : i64
  (match s
    [(SpannedToken _ _ col) col]))

(define (spanned-token-token [s : SpannedToken]) : Token
  (spanned-token-tok s))

(define (spanned-token-span [s : SpannedToken]) : SourceSpan
  (SourceSpan
    (spanned-token-line s)
    (spanned-token-col s)
    (spanned-token-line s)
    (spanned-token-col s)))

;; ---- Token-kind tag constants (kept in sync with `token-tag`). ----

;; A parser compares a token's tag against these to drive its descent.

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