;; lexer.tl — A tokenizer written in TypeLisp itself.
;;
;; This is the first compiler front-end component authored *in* TypeLisp, the
;; opening slice of the self-hosting milestone (#27, phase 4). It scans a
;; hardcoded source String character-by-character and produces a token stream,
;; proving the language primitives — String indexing (`string-ref`,
;; `string-length`), `substring` (#104), `char`->`i64` casts and comparison,
;; `defenum` + `match` with String-payload variants (#101), `while`/`let`/
;; `set!`/`begin`, and a dynamic `(Array i64)` — compose into the scanning loop
;; a real lexer needs.
;;
;; Token grammar handled this slice (a tiny arithmetic + identifier surface):
;;   identifiers (an ASCII letter or `_`, then letters/digits/`_`),
;;   integers (one or more decimal digits), `+`, `(`, `)`, and whitespace
;;   (space / tab / newline, which separate tokens but emit nothing).
;; An unexpected character aborts the program via the `panic` builtin (#45),
;; exactly as a real lexer reports malformed input.
;;
;; Identifiers carry their text: when the scanner sees a letter it records the
;; start index, advances over the identifier run, and slices the lexeme out of
;; the source with `substring`, producing a real `(TIdent text)` token — the
;; String-payload enum variant (#101) constructed, returned across a function
;; boundary (heap-promoted), and projected back out in a `match` arm. This is
;; the substring (#104) + String-payload variant (#101) composition a usable
;; lexer needs.
;;
;; Deferred — current language gaps, recorded as self-hosting signal:
;;   - Tokens are recorded as numeric *tags* in an `(Array i64)` rather than as
;;     `Token` aggregates, because dynamic arrays of enum payloads do not lower
;;     yet (#106). The full `Token` enum — including the `(TIdent String)`
;;     payload variant — is still constructed and `match`ed on the identifier
;;     path, and its tag recorded in the stream; the identifier text is returned
;;     to `main` through a separate `(TIdent text)`-valued helper.
;;   - Digit char literals: `#\0` lexes as NUL (the `\0` escape), so digit and
;;     whitespace classification compares the char's `i64` code point against
;;     ASCII constants rather than against char literals.

(defenum Token
  (TIdent String)
  (TInt i64)
  (TPlus)
  (TLParen)
  (TRParen)
  (TEnd))

;; Numeric tag for a token kind, so a token stream can be recorded in a dynamic
;; i64 array (arrays of enum aggregates do not lower yet, #106). Exercises
;; `match` over every variant of the Token enum, including the String-payload
;; `TIdent` variant whose payload is bound but unused here.
(define (token-tag [t : Token]) : i64
  (match t
    [(TIdent _) 0]
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

;; `c` is an ASCII letter (A-Z == 65..90, a-z == 97..122) or `_` (95): the set
;; of characters that may *start* an identifier.
(define (is-alpha [c : char]) : bool
  (let ([k : i64 (code c)])
    (or (= k 95)
        (or (and (>= k 65) (<= k 90))
            (and (>= k 97) (<= k 122))))))

;; `c` may appear in an identifier after the first char: a letter, `_`, or a
;; digit.
(define (is-ident-char [c : char]) : bool
  (or (is-alpha c) (is-digit c)))

;; `c` is ASCII whitespace: space (32), tab (9), or newline (10).
(define (is-space [c : char]) : bool
  (let ([k : i64 (code c)])
    (or (= k 32) (or (= k 9) (= k 10)))))

;; Decimal value of a digit char, e.g. the digit char `7` -> 7.
(define (digit-value [c : char]) : i64
  (- (code c) 48))

;; Classify a single (non-digit, non-letter, non-space) char into its Token,
;; building an actual `Token` value so enum construction is exercised. An
;; unexpected char aborts via the `panic` builtin (#45); the trailing `TEnd` is
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

;; Return the end index (exclusive) of the identifier that starts at `start`
;; in `src`: scan forward over identifier characters. `n` is the source length.
(define (ident-end [src : String] [start : i64] [n : i64]) : i64
  (let ([j : i64 start])
    (begin
      (while (and (< j n) (is-ident-char (string-ref src j)))
        (set! j (+ j 1)))
      j)))

;; Slice the identifier lexeme [start, end) out of `src` and wrap it in a real
;; `(TIdent text)` token. This is the capability a real lexer needs: the
;; substring (#104) of the source becomes the String payload of the token
;; (#101), constructed here and returned to the caller (heap-promoted).
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
    [(TLParen) 0]
    [(TRParen) 0]
    [(TEnd) 0]))

;; Lex `src`, recording each token's numeric tag into `tags` (which must be
;; large enough to hold every token) and returning the token count. The loop
;; is exactly the shape of a real lexer: a cursor over the input, a whitespace
;; skip, multi-char accumulation for integers, an identifier run sliced out
;; with `substring` into a real `(TIdent text)` token, and single-char tokens.
(define (lex [src : String] [tags : (Array i64)]) : i64
  (let ([i : i64 0]
        [n : i64 (string-length src)]
        [count : i64 0])
    (begin
      (while (< i n)
        (let ([c : char (string-ref src i)])
          (if (is-space c)
              (set! i (+ i 1))
              (if (is-alpha c)
                  ;; Accumulate a run of identifier chars into one TIdent token,
                  ;; slicing the lexeme out of the source with `substring`.
                  (let ([start : i64 i]
                        [end : i64 (ident-end src i n)])
                    (begin
                      (array-set! tags count (token-tag (ident-token src start end)))
                      (set! count (+ count 1))
                      (set! i end)))
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
                        (set! i (+ i 1))))))))
      ;; A real lexer terminates the stream; record the sentinel too.
      (array-set! tags count (token-tag TEnd))
      count)))

;; Scan the first identifier token out of `src` and return it as a real
;; `(TIdent text)` value, skipping any leading non-identifier characters.
;; Returns `TEnd` if the source holds no identifier. This drives the substring
;; + String-payload path end to end: the returned token carries the identifier
;; text sliced from the source.
(define (first-ident [src : String]) : Token
  (let ([i : i64 0]
        [n : i64 (string-length src)]
        [result : Token TEnd]
        [done : i64 0])
    (begin
      ;; `done` is an i64 flag (0 = keep scanning, 1 = found): there is no
      ;; boolean `not`/`=` on bool today, so the loop guard tests it as an int.
      (while (and (< i n) (= done 0))
        (let ([c : char (string-ref src i)])
          (if (is-alpha c)
              (let ([end : i64 (ident-end src i n)])
                (begin
                  (set! result (ident-token src i end))
                  (set! done 1)))
              (set! i (+ i 1)))))
      result)))

;; Lex the sample `"foo + (12)"`:
;;   - Full token stream (excluding the TEnd sentinel): TIdent("foo") TPlus
;;     TLParen TInt(12) TRParen => 5 tokens.
;;   - The first identifier is "foo", whose text length is 3.
;; main returns 5 + 3 = 8, an observable result an execution test can check
;; that depends on BOTH the token count AND the substring-sliced identifier.
(define (main) : i64
  (let ([tags : (Array i64) (make-array i64 16)])
    (+ (lex "foo + (12)" tags)
       (ident-text-length (first-ident "foo + (12)")))))
