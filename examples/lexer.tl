;; lexer.tl - A tokenizer written in TypeLisp itself.
;;
;; This is the first compiler front-end component authored in TypeLisp, the
;; opening slice of the self-hosting milestone (#27, phase 4). It scans a
;; hardcoded source String character-by-character and produces a token stream,
;; proving the language primitives - String indexing (`string-ref`,
;; `string-length`), `substring` (#104), `char`->`i64` casts and comparison,
;; `defenum` + `match` with String-payload variants (#101), `while`/`let`/
;; `set!`/`begin`, and a generated vector of `Token` aggregates compose into
;; the scanning loop a real lexer needs.
;;
;; Token grammar handled this slice (a tiny arithmetic + identifier surface):
;;   identifiers (an ASCII letter or `_`, then letters/digits/`_`),
;;   integers (one or more decimal digits), the operators `+` `-` `*` `/`,
;;   `(`, `)`, and whitespace (space / tab / newline, which separate tokens but
;;   emit nothing).
;; An unexpected character aborts the program via the `panic` builtin (#45),
;; exactly as a real lexer reports malformed input.
;;
;; Token stream representation (refs #13/#27/#41): the scanner records each
;; emitted token as a real `Token` value in a generated `Token` vector. Identifier
;; tokens carry a `String` payload sliced out of the source with `substring`, so
;; vector reads can return a `(Token.Ident text)` token whose payload is still
;; projectable through `match`.
;;
;; Deferred - current language gaps, recorded as self-hosting signal:
;;   - Digit and whitespace classification compares each char's `i64` code
;;     point against ASCII constants.
(import "stdlib/io.tl")
(import "stdlib/string.tl")
(import stdlib.vector)

(defenum Token
  (Ident String)
  (Int i64)
  (Plus)
  (Minus)
  (Star)
  (Slash)
  (LParen)
  (RParen)
  (End))

(import (vector.vector Token) as token_vec)

;; Numeric tag for a token kind. Exercises `match` over every variant of the
;; Token enum, including the String-payload `Token.Ident` variant.
(define (token-tag [t : Token]) : i64
  (match t
    [(Token.Ident _) 0]
    [(Token.Int _) 1]
    [(Token.Plus) 2]
    [(Token.Minus) 3]
    [(Token.Star) 4]
    [(Token.Slash) 5]
    [(Token.LParen) 6]
    [(Token.RParen) 7]
    [(Token.End) 8]))

;; ASCII code point of a char, e.g. the digit char `7` -> 55.
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char.
(define (is-digit [c : char]) : bool
  (and (>= c '0') (<= c '9')))

;; `c` is an ASCII letter (A-Z, a-z) or `_`: the set of characters that may
;; start an identifier.
(define (is-alpha [c : char]) : bool
  (or (= c '_') (and (>= c 'A') (<= c 'Z')) (and (>= c 'a') (<= c 'z'))))

;; `c` may appear in an identifier after the first char: a letter, `_`, or a
;; digit.
(define (is-ident-char [c : char]) : bool
  (or (is-alpha c) (is-digit c)))

;; `c` is ASCII whitespace: space, tab, or newline.
(define (is-space [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n')))

;; Decimal value of a digit char, e.g. the digit char `7` -> 7.
(define (digit-value [c : char]) : i64
  (- (code c) (code '0')))

;; Classify a single (non-digit, non-letter, non-space) char into its Token,
;; building an actual `Token` value so enum construction is exercised. An
;; unexpected char aborts via the `panic` builtin (#45); the trailing
;; `Token.End` is dead code that only satisfies the `Token` result type, since
;; `panic` yields unit and never returns.
(define (single-token [c : char]) : Token
  (cond
    [(= c '+') Token.Plus]
    [(= c '-') Token.Minus]
    [(= c '*') Token.Star]
    [(= c '/') Token.Slash]
    [(= c '(') Token.LParen]
    [(= c ')') Token.RParen]
    [else (panic "lexer: unexpected character")]))

;; Return the end index (exclusive) of the identifier that starts at `start`
;; in `src`: scan forward over identifier characters. `n` is the source length.
(define (ident-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    (begin
      (while (and (< j n) (is-ident-char (string-ref src j)))
        (set! j (+ j 1)))
      j)))

;; Slice the identifier lexeme [start, end) out of `src` and wrap it in a real
;; `(Token.Ident text)` token.
(define (ident-token [src : String] [start : i64] [end : i64]) : Token
  (Token.Ident (substring src start (- end start))))

;; Length of the String payload of a `Token.Ident` token (0 for any other token):
;; projects the payload back out of the enum in a `match` arm, the way a parser
;; consuming the token stream would.
(define (ident-text-length [t : Token]) : i64
  (match t
    [(Token.Ident s) (string-length s)]
    [(Token.Int _) 0]
    [(Token.Plus) 0]
    [(Token.Minus) 0]
    [(Token.Star) 0]
    [(Token.Slash) 0]
    [(Token.LParen) 0]
    [(Token.RParen) 0]
    [(Token.End) 0]))

;; Lex `src`, appending each emitted `Token` value into `toks` and returning the
;; token count. The loop is exactly the shape of a real lexer: a cursor over the
;; input, a whitespace skip, multi-char accumulation for integers, an identifier
;; run sliced out with `substring`, and single-char tokens.
(define (lex [src : String] [toks : (&mut toks token_vec.Vec)]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length src)]
    [count : i64 0]
    (begin
      (while (< i n)
        (let
          [c : char (string-ref src i)]
          (cond
            [(is-space c) (set! i (+ i 1))]
            [(is-alpha c)
              ;; Accumulate a run of identifier chars into one `Token.Ident` token.
              (let
                [start : i64 i]
                [end : i64 (ident-end src i n)]
                (begin
                  (token_vec.push toks (ident-token src start end))
                  (set! count (+ count 1))
                  (set! i end)))]
            [(is-digit c)
              ;; Accumulate a run of digits into one `Token.Int` token.
              (let
                [acc : i64 0]
                (begin
                  (while (and (< i n) (is-digit (string-ref src i)))
                    (begin
                      (set! acc (+ (* acc 10) (digit-value (string-ref src i))))
                      (set! i (+ i 1))))
                  (token_vec.push toks (Token.Int acc))
                  (set! count (+ count 1))))]
            [else
              (begin
                (token_vec.push toks (single-token c))
                (set! count (+ count 1))
                (set! i (+ i 1)))])))
      ;; A real lexer terminates the stream; record the sentinel too.
      (token_vec.push toks Token.End)
      count)))

;; Lex the sample `"foo - 3 * (12 / 4)"` (exercises every operator `- * /` and
;; the parens):
;;   - Full token stream (excluding the `Token.End` sentinel):
;;     `Token.Ident("foo")`, `Token.Minus`, `Token.Int(3)`, `Token.Star`,
;;     `Token.LParen`, `Token.Int(12)`, `Token.Slash`, `Token.Int(4)`,
;;     `Token.RParen` => 9 tokens.
;;   - Token 0 is read back out of the token vector as
;;     `(Token.Ident "foo")`, whose text length is 3.
;; main returns 9 + 3 = 12, an observable result an execution test can check
;; that depends on both the token count and the substring-sliced identifier.
(define (main) : i64
  (let
    [toks : token_vec.Vec (token_vec.with-capacity 16)]
    [count : i64 (lex "foo - 3 * (12 / 4)" (&mut toks))]
    (+ count (ident-text-length (token_vec.get (& toks) 0 Token.End)))))