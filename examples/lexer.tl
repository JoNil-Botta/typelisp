;; lexer.tl — A tokenizer written in TypeLisp itself.
;;
;; This is the first compiler front-end component authored *in* TypeLisp, the
;; opening slice of the self-hosting milestone (#27, phase 4). It scans a
;; hardcoded source String character-by-character and produces a token stream,
;; proving the language primitives — String indexing (`string-ref`,
;; `string-length`), `char`->`i64` casts and comparison, `defenum` + `match`,
;; `while`/`let`/`set!`/`begin`, and a dynamic array of `Token` AGGREGATES
;; (`(Array Token)`) — compose into the scanning loop a real lexer needs.
;;
;; Token grammar handled this slice (a tiny arithmetic surface):
;;   integers (one or more decimal digits), `+`, `(`, `)`, and whitespace
;;   (space / tab / newline, which separate tokens but emit nothing).
;; An unexpected character aborts the program via the `panic` builtin (#45),
;; exactly as a real lexer reports malformed input.
;;
;; Token stream representation (refs #13/#27/#41): the scanner now records each
;; emitted token as a real `Token` value in a dynamic `(Array Token)` — a
;; dynamic array of enum aggregates. Each element is a pointer to the token's
;; inline `{ tag, payload }` storage; `array-set!` stores that pointer and
;; `array-ref` reads it back as a `Token` that `match` can project (see
;; `main`, which reads token 0 back out and tags it). This replaces the earlier
;; workaround that stored numeric *tags* in an `(Array i64)` because dynamic
;; arrays of enum payloads did not lower.
;;
;; Deferred — current language gaps, recorded as self-hosting signal:
;;   - Identifiers / keywords (`TIdent`): a String-payload variant token kind is
;;     not added to this slice's grammar yet, so identifier tokens are skipped.
;;   - Digit char literals: `#\0` lexes as NUL (the `\0` escape), so digit and
;;     whitespace classification compares the char's `i64` code point against
;;     ASCII constants rather than against char literals.

(defenum Token
  (TInt i64)
  (TPlus)
  (TLParen)
  (TRParen)
  (TEnd))

;; Numeric tag for a token kind. Exercises `match` over every variant of the
;; Token enum, and is used to project a `Token` read back out of the token
;; array (proving the aggregate round-trips through `(Array Token)`).
(define (token-tag [t : Token]) : i64
  (match t
    [(TInt _) 1]
    [(TPlus) 2]
    [(TLParen) 3]
    [(TRParen) 4]
    [(TEnd) 5]))

;; ASCII code point of a char, e.g. the digit char `7` -> 55.
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char (ASCII '0'..'9' == 48..57).
(define (is-digit [c : char]) : bool
  (and (>= (code c) 48) (<= (code c) 57)))

;; `c` is ASCII whitespace: space (32), tab (9), or newline (10).
(define (is-space [c : char]) : bool
  (let ([k : i64 (code c)])
    (or (= k 32) (or (= k 9) (= k 10)))))

;; Decimal value of a digit char, e.g. the digit char `7` -> 7.
(define (digit-value [c : char]) : i64
  (- (code c) 48))

;; Classify a single (non-digit, non-space) char into its Token, building an
;; actual `Token` value so enum construction is exercised. An unexpected char
;; aborts the program via the `panic` builtin (#45); the trailing `TEnd` is
;; dead code that only satisfies the `Token` result type, since `panic` yields
;; unit and never returns.
(define (single-token [c : char]) : Token
  (if (= (code c) 43)            ; '+'
      TPlus
      (if (= (code c) 40)        ; '('
          TLParen
          (if (= (code c) 41)    ; ')'
              TRParen
              (begin
                (panic "lexer: unexpected character")
                TEnd)))))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. The loop is exactly the shape of a real lexer: a cursor over the
;; input, a whitespace skip, multi-char accumulation for integers, and
;; single-char tokens. Each `(array-set! toks count <Token>)` stores a real
;; constructed `Token` aggregate into the `(Array Token)`.
(define (lex [src : String] [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [n : i64 (string-length src)]
        [count : i64 0])
    (begin
      (while (< i n)
        (let ([c : char (string-ref src i)])
          (if (is-space c)
              (set! i (+ i 1))
              (if (is-digit c)
                  ;; Accumulate a run of digits into one TInt token.
                  (let ([acc : i64 0])
                    (begin
                      (while (and (< i n) (is-digit (string-ref src i)))
                        (begin
                          (set! acc (+ (* acc 10) (digit-value (string-ref src i))))
                          (set! i (+ i 1))))
                      (array-set! toks count (TInt acc))
                      (set! count (+ count 1))))
                  (begin
                    (array-set! toks count (single-token c))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))))))
      ;; A real lexer terminates the stream; record the sentinel too.
      (array-set! toks count TEnd)
      count)))

;; Lex the sample `"12 + (34)"`, store the tokens as real `Token` aggregates,
;; then read the first token back out of the array and project it with
;; `token-tag` — proving a `Token` round-trips through `(Array Token)`.
;; Tokens: TInt(12) TPlus TLParen TInt(34) TRParen => first token is TInt, so
;; reading token 0 back and tagging it yields 1.
(define (main) : i64
  (let ([toks : (Array Token) (make-array Token 16)])
    (begin
      (lex "12 + (34)" toks)
      (token-tag (array-ref toks 0)))))
