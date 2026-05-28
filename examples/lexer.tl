;; lexer.tl - A tokenizer written in TypeLisp itself.
;;
;; This is the first compiler front-end component authored in TypeLisp, the
;; opening slice of the self-hosting milestone (#27, phase 4). It scans a
;; hardcoded source String character-by-character and produces a token stream,
;; proving the language primitives - String indexing (`string-ref`,
;; `string-length`), `substring` (#104), `char`->`i64` casts and comparison,
;; `defenum` + `match` with String-payload variants (#101), `while`/`let`/
;; `set!`/`begin`, and a dynamic array of `Token` aggregates (`(Array Token)`)
;; - compose into the scanning loop a real lexer needs.
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
;; emitted token as a real `Token` value in a dynamic `(Array Token)`. Identifier
;; tokens carry a `String` payload sliced out of the source with `substring`, so
;; `array-ref` can read back a `(TIdent text)` token whose payload is still
;; projectable through `match`.
;;
;; Deferred - current language gaps, recorded as self-hosting signal:
;;   - Digit char literals: `#\0` lexes as NUL (the `\0` escape), so digit and
;;     whitespace classification compares the char's `i64` code point against
;;     ASCII constants rather than against char literals.
(defenum Token
  (TIdent String)
  (TInt i64)
  (TPlus)
  (TMinus)
  (TStar)
  (TSlash)
  (TLParen)
  (TRParen)
  (TEnd))

;; Numeric tag for a token kind. Exercises `match` over every variant of the
;; Token enum, including the String-payload `TIdent` variant.
(define (token-tag [t : Token]) : i64
  (match t
    [(TIdent _) 0]
    [(TInt _) 1]
    [(TPlus) 2]
    [(TMinus) 3]
    [(TStar) 4]
    [(TSlash) 5]
    [(TLParen) 6]
    [(TRParen) 7]
    [(TEnd) 8]))

;; ASCII code point of a char, e.g. the digit char `7` -> 55.
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char.
(define (is-digit [c : char]) : bool
  (and (>= c #0') (<= c #9')))

;; `c` is an ASCII letter (A-Z, a-z) or `_`: the set of characters that may
;; start an identifier.
(define (is-alpha [c : char]) : bool
  (or (= c #_') (or (and (>= c #A') (<= c #Z')) (and (>= c #a') (<= c #z')))))

;; `c` may appear in an identifier after the first char: a letter, `_`, or a
;; digit.
(define (is-ident-char [c : char]) : bool
  (or (is-alpha c) (is-digit c)))

;; `c` is ASCII whitespace: space, tab, or newline.
(define (is-space [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (= c #\newline'))))

;; Decimal value of a digit char, e.g. the digit char `7` -> 7.
(define (digit-value [c : char]) : i64
  (- (code c) (code #0')))

;; Classify a single (non-digit, non-letter, non-space) char into its Token,
;; building an actual `Token` value so enum construction is exercised. An
;; unexpected char aborts via the `panic` builtin (#45); the trailing `TEnd` is
;; dead code that only satisfies the `Token` result type, since `panic` yields
;; unit and never returns.
(define (single-token [c : char]) : Token
  (cond
    [(= c #+') TPlus]
    [(= c #-') TMinus]
    [(= c #*') TStar]
    [(= c #/') TSlash]
    [(= c #(') TLParen]
    [(= c #)') TRParen]
    [else
      (begin
        (panic "lexer: unexpected character")
        TEnd)]))

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
;; `(TIdent text)` token.
(define (ident-token [src : String] [start : i64] [end : i64]) : Token
  (TIdent (substring src start (- end start))))

;; Length of the String payload of a `TIdent` token (0 for any other token):
;; projects the payload back out of the enum in a `match` arm, the way a parser
;; consuming the token stream would.
(define (ident-text-length [t : Token]) : i64
  (match t
    [(TIdent s) (string-length s)]
    [(TInt _) 0]
    [(TPlus) 0]
    [(TMinus) 0]
    [(TStar) 0]
    [(TSlash) 0]
    [(TLParen) 0]
    [(TRParen) 0]
    [(TEnd) 0]))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. The loop is exactly the shape of a real lexer: a cursor over the
;; input, a whitespace skip, multi-char accumulation for integers, an identifier
;; run sliced out with `substring`, and single-char tokens.
(define (lex [src : String] [toks : (Array Token)]) : i64
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
              ;; Accumulate a run of identifier chars into one TIdent token.
              (let
                [start : i64 i]
                [end : i64 (ident-end src i n)]
                (begin
                  (array-set! toks count (ident-token src start end))
                  (set! count (+ count 1))
                  (set! i end)))]
            [(is-digit c)
              ;; Accumulate a run of digits into one TInt token.
              (let
                [acc : i64 0]
                (begin
                  (while (and (< i n) (is-digit (string-ref src i)))
                    (begin
                      (set! acc (+ (* acc 10) (digit-value (string-ref src i))))
                      (set! i (+ i 1))))
                  (array-set! toks count (TInt acc))
                  (set! count (+ count 1))))]
            [else
              (begin
                (array-set! toks count (single-token c))
                (set! count (+ count 1))
                (set! i (+ i 1)))])))
      ;; A real lexer terminates the stream; record the sentinel too.
      (array-set! toks count TEnd)
      count)))

;; Lex the sample `"foo - 3 * (12 / 4)"` (exercises every operator `- * /` and
;; the parens):
;;   - Full token stream (excluding the TEnd sentinel): TIdent("foo") TMinus
;;     TInt(3) TStar TLParen TInt(12) TSlash TInt(4) TRParen => 9 tokens.
;;   - Token 0 is read back out of `(Array Token)` as `(TIdent "foo")`, whose
;;     text length is 3.
;; main returns 9 + 3 = 12, an observable result an execution test can check
;; that depends on both the token count and the substring-sliced identifier.
(define (main) : i64
  (let
    [toks : (Array Token) (make-array Token 16)]
    (let
      [count : i64 (lex "foo - 3 * (12 / 4)" toks)]
      (+ count (ident-text-length (array-ref toks 0))))))