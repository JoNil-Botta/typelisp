;; lexer.tl — A tokenizer written in TypeLisp itself.
;;
;; This is the first compiler front-end component authored *in* TypeLisp, the
;; opening slice of the self-hosting milestone (#27, phase 4). It scans a
;; hardcoded source String character-by-character and produces a token stream,
;; proving the language primitives — String indexing (`string-ref`,
;; `string-length`), `char`->`i64` casts and comparison, `defenum` + `match`,
;; `while`/`let`/`set!`/`begin`, and a dynamic `(Array i64)` — compose into the
;; scanning loop a real lexer needs.
;;
;; Token grammar handled this slice (a tiny arithmetic surface):
;;   integers (one or more decimal digits), `+`, `(`, `)`, and whitespace
;;   (space / tab / newline, which separate tokens but emit nothing).
;; An unexpected character aborts the program via the `panic` builtin (#45),
;; exactly as a real lexer reports malformed input.
;;
;; Deferred — current language gaps, recorded as self-hosting signal:
;;   - Identifiers / keywords (`TIdent`): String-payload enum variants are not
;;     constructible+returnable cleanly today, so identifier tokens are skipped.
;;   - Tokens are recorded as numeric *tags* in an `(Array i64)` rather than as
;;     `Token` aggregates, because dynamic arrays of enum payloads do not lower
;;     yet. The `Token` enum and its `match`-based projections are still
;;     exercised on every emitted token.
;;   - Digit char literals: `#\0` lexes as NUL (the `\0` escape), so digit and
;;     whitespace classification compares the char's `i64` code point against
;;     ASCII constants rather than against char literals.

(defenum Token
  (TInt i64)
  (TPlus)
  (TLParen)
  (TRParen)
  (TEnd))

;; Numeric tag for a token kind, so a token stream can be recorded in a dynamic
;; i64 array (arrays of enum aggregates do not lower yet). Exercises `match`
;; over every variant of the Token enum.
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

;; Lex `src`, recording each token's numeric tag into `tags` (which must be
;; large enough to hold every token) and returning the token count. The loop
;; is exactly the shape of a real lexer: a cursor over the input, a whitespace
;; skip, multi-char accumulation for integers, and single-char tokens.
(define (lex [src : String] [tags : (Array i64)]) : i64
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
                      (array-set! tags count (token-tag (TInt acc)))
                      (set! count (+ count 1))))
                  (begin
                    (array-set! tags count (token-tag (single-token c)))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))))))
      ;; A real lexer terminates the stream; record the sentinel too.
      (array-set! tags count (token-tag TEnd))
      count)))

;; Lex the sample `"12 + (34)"` and return the token count (excluding the
;; TEnd sentinel). Tokens: TInt(12) TPlus TLParen TInt(34) TRParen => 5.
(define (main) : i64
  (let ([tags : (Array i64) (make-array i64 16)])
    (lex "12 + (34)" tags)))
