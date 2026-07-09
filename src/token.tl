;; token.tl - The token model for a lexer of TypeLisp's OWN s-expression
;; syntax, factored out as a `main`-less, importable module.
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
;; Why this is a separate, importable module.
;; --------------------------------------------------------------------------
;; The module loader is whole-program: it concatenates every imported
;; module's declarations into a single `Program`, imported-before-importer, then
;; runs the unchanged `typecheck -> lower -> codegen` pipeline. So:
;;
;;   - The imported `defenum Token` defines ONE nominal type. The importer's
;;     `Token` parameters/locals and the `Token` values its lexer constructs all
;;     refer to that same type - there is no per-module enum identity.
;;   - The constructors (`Token.LParen`, `Token.Int`, `Token.Sym`, ...) and the
;;     accessors' `match` arms defined here are usable from the importer as if
;;     local.
;;   - Because this module declares no `main`, concatenation yields exactly one
;;     `main` (the importer's) - no duplicate-symbol clash.
;; The token kinds TypeLisp's s-expression surface needs: an opening paren, a
;; closing paren, an integer or float literal, a symbol (any operator / keyword / name -
;; carries an interned lexeme id), a string literal (`"..."`, carries the
;; sliced inner text), a character literal (`'x'`, carries the char),
;; and an end-of-stream sentinel. `Token.Str`, `Token.Char`, and `Token.Float`
;; are appended last so the existing variants/tags keep their stable ordering
;; for every importer.
(import compiler_intern as ci)

(defenum Token
  (LParen)
  (RParen)
  (Int i64 String)
  (Sym i64)
  (End)
  (Str String)
  (Char char)
  (Float String)
  (LBracket)
  (RBracket)
  (Quote)
  (Backtick)
  (Comma)
  (CommaAt))

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

(define (source-span-new
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : SourceSpan
  (SourceSpan start-line start-col end-line end-col))

(define (source-error-new [message : String] [span : SourceSpan]) : SourceError
  (SourceError message span))

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
    (= (span-start-col span) start-col)
    (= (span-end-line span) end-line)
    (= (span-end-col span) end-col)))

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
;; i64-payload `Token.Sym` and the source-preserving `Token.Int`.
(define (tag [t : Token]) : i64
  (match t
    [(Token.LParen) 1]
    [(Token.RParen) 2]
    [(Token.Int _ _) 3]
    [(Token.Sym _) 4]
    [(Token.End) 5]
    [(Token.Str _) 6]
    [(Token.Char _) 7]
    [(Token.Float _) 8]
    [(Token.LBracket) 9]
    [(Token.RBracket) 10]
    [(Token.Quote) 11]
    [(Token.Backtick) 12]
    [(Token.Comma) 13]
    [(Token.CommaAt) 14]))

;; Integer payload of `Token.Int` (0 for any other kind): projects the literal
;; value back out of the enum, the way a parser reads a numeric literal.
(define (int [t : Token]) : i64
  (match t
    [(Token.LParen) 0]
    [(Token.RParen) 0]
    [(Token.Int v _) v]
    [(Token.Sym _) 0]
    [(Token.End) 0]
    [(Token.Str _) 0]
    [(Token.Char _) 0]
    [(Token.Float _) 0]
    [(Token.LBracket) 0]
    [(Token.RBracket) 0]
    [(Token.Quote) 0]
    [(Token.Backtick) 0]
    [(Token.Comma) 0]
    [(Token.CommaAt) 0]))

;; Original source spelling of `Token.Int` (empty string for any other kind).
(define (int-text [t : Token]) : String
  (match t
    [(Token.LParen) ""]
    [(Token.RParen) ""]
    [(Token.Int _ text) text]
    [(Token.Sym _) ""]
    [(Token.End) ""]
    [(Token.Str _) ""]
    [(Token.Char _) ""]
    [(Token.Float _) ""]
    [(Token.LBracket) ""]
    [(Token.RBracket) ""]
    [(Token.Quote) ""]
    [(Token.Backtick) ""]
    [(Token.Comma) ""]
    [(Token.CommaAt) ""]))

;; Symbol intern id of `Token.Sym` (-1 for any other kind): exposes the compact
;; lexer representation to callers that can stay id-native.
(define (sym-id [t : Token]) : i64
  (match t
    [(Token.LParen) -1]
    [(Token.RParen) -1]
    [(Token.Int _ _) -1]
    [(Token.Sym id) id]
    [(Token.End) -1]
    [(Token.Str _) -1]
    [(Token.Char _) -1]
    [(Token.Float _) -1]
    [(Token.LBracket) -1]
    [(Token.RBracket) -1]
    [(Token.Quote) -1]
    [(Token.Backtick) -1]
    [(Token.Comma) -1]
    [(Token.CommaAt) -1]))

;; Symbol text of `Token.Sym` (the empty string for any other kind): resolves
;; the interned lexeme id back to text, the way a parser reads a symbol/name.
(define (sym [t : Token]) : String
  (match t
    [(Token.LParen) ""]
    [(Token.RParen) ""]
    [(Token.Int _ _) ""]
    [(Token.Sym id) (ci.intern-str id)]
    [(Token.End) ""]
    [(Token.Str _) ""]
    [(Token.Char _) ""]
    [(Token.Float _) ""]
    [(Token.LBracket) ""]
    [(Token.RBracket) ""]
    [(Token.Quote) ""]
    [(Token.Backtick) ""]
    [(Token.Comma) ""]
    [(Token.CommaAt) ""]))

;; String text of `Token.Str` (the empty string for any other kind): projects
;; the sliced inner text of a `"..."` literal back out of the enum, the way a
;; parser reads a string-literal datum. Distinct from `sym` so a
;; `Token.Str` and a `Token.Sym` with the same characters stay distinguishable.
(define (str [t : Token]) : String
  (match t
    [(Token.LParen) ""]
    [(Token.RParen) ""]
    [(Token.Int _ _) ""]
    [(Token.Sym _) ""]
    [(Token.End) ""]
    [(Token.Str s) s]
    [(Token.Char _) ""]
    [(Token.Float _) ""]
    [(Token.LBracket) ""]
    [(Token.RBracket) ""]
    [(Token.Quote) ""]
    [(Token.Backtick) ""]
    [(Token.Comma) ""]
    [(Token.CommaAt) ""]))

;; Float literal text of `Token.Float` (the empty string for any other kind):
;; the selfhost frontend carries source spelling until backend emission, so it
;; does not need a string->f64 primitive.
(define (float [t : Token]) : String
  (match t
    [(Token.LParen) ""]
    [(Token.RParen) ""]
    [(Token.Int _ _) ""]
    [(Token.Sym _) ""]
    [(Token.End) ""]
    [(Token.Str _) ""]
    [(Token.Char _) ""]
    [(Token.Float s) s]
    [(Token.LBracket) ""]
    [(Token.RBracket) ""]
    [(Token.Quote) ""]
    [(Token.Backtick) ""]
    [(Token.Comma) ""]
    [(Token.CommaAt) ""]))

;; Character payload of `Token.Char` (NUL for any other kind): projects the
;; read character back out of the enum while keeping char atoms distinct from
;; symbols, ints, and strings.
(define (char [t : Token]) : char
  (match t
    [(Token.LParen) '\0']
    [(Token.RParen) '\0']
    [(Token.Int _ _) '\0']
    [(Token.Sym _) '\0']
    [(Token.End) '\0']
    [(Token.Str _) '\0']
    [(Token.Char c) c]
    [(Token.Float _) '\0']
    [(Token.LBracket) '\0']
    [(Token.RBracket) '\0']
    [(Token.Quote) '\0']
    [(Token.Backtick) '\0']
    [(Token.Comma) '\0']
    [(Token.CommaAt) '\0']))

;; A token paired with the 1-based source line and column where its lexeme
;; begins. The reader/parser recover positions from these so later
;; diagnostics can point at the originating source location. `Token.End` carries
;; the position one past the last character. This is additive: the plain `Token`
;; stream and its accessors are unchanged, so existing callers keep working.
(defenum SpannedToken
  (Spanned Token i64 i64))

(define (spanned-token-new [tok : Token] [line : i64] [col : i64]) : SpannedToken
  (SpannedToken.Spanned tok line col))

(define (spanned-token-tok [s : SpannedToken]) : Token
  (match s
    [(SpannedToken.Spanned t _ _) t]))

(define (spanned-token-line [s : SpannedToken]) : i64
  (match s
    [(SpannedToken.Spanned _ line _) line]))

(define (spanned-token-col [s : SpannedToken]) : i64
  (match s
    [(SpannedToken.Spanned _ _ col) col]))

(define (spanned-token-token [s : SpannedToken]) : Token
  (spanned-token-tok s))

(define (spanned-token-span [s : SpannedToken]) : SourceSpan
  (SourceSpan
    (spanned-token-line s)
    (spanned-token-col s)
    (spanned-token-line s)
    (spanned-token-col s)))

;; ---- Token-kind tag constants (kept in sync with `tag`). ----
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

(define (tag-quote) : i64
  11)

(define (tag-backtick) : i64
  12)

(define (tag-comma) : i64
  13)

(define (tag-comma-at) : i64
  14)