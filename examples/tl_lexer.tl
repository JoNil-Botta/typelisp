;; tl_lexer.tl - A lexer for TypeLisp's OWN s-expression syntax, written in
;; TypeLisp itself. The first piece of the *real* self-hosting compiler front end
;; (#27): it tokenizes actual TypeLisp source - the surface this very file is
;; written in - rather than the arithmetic-calculator surface that `lexer.tl` /
;; `calc.tl` exercise.
;;
;; --------------------------------------------------------------------------
;; What "TypeLisp's own syntax" means for the tokenizer.
;; --------------------------------------------------------------------------
;; TypeLisp source is s-expressions: balanced parentheses around atoms. An atom
;; is either an integer literal or a *symbol* - and in an s-expression language a
;; symbol is everything else that is one contiguous lexeme: an operator (`+`), a
;; comparison (`<=`), a keyword (`define`, `let`, `while`), a builtin name
;; (`string->int`, `array-set!`), or a user name (`parse-expr`). So the lexer
;; does NOT recognise a fixed operator alphabet the way the calculator lexer
;; does; it slices each maximal symbol/int run out of the source. The token kinds
;; collapse to: `(` `)` integer symbol end (see the imported `tl_token.tl`).
;;
;; The scan loop is the shape of a real lexer: a cursor over the input, a
;; whitespace skip, single-char paren tokens, a digit run sliced into a
;; `(TInt (string->int ...))`, and a symbol run sliced into a `(TSym ...)` with
;; `substring`. An unexpected character aborts via the `panic` builtin (#45),
;; exactly as a real lexer reports malformed input.
;;
;; Deferred - current scope boundaries, recorded as self-hosting signal:
;;   - String literals (`"..."`), char literals (`#\a`), and comments (`;`),
;;     which need lexer state machines beyond this slice.
;;   - Keyword classification: keywords are lexed as plain `TSym` tokens here; a
;;     later pass (or the parser) distinguishes `define`/`let`/... from names.
;;   - Digit char literals: `#\0` lexes as NUL, so digit/whitespace/symbol
;;     classification compares the char's `i64` code point against ASCII
;;     constants rather than against char literals.

;; The shared token model: the `Token` enum and the `token-tag` / `token-int` /
;; `token-sym` accessors. Resolved relative to this file, so it finds the
;; co-located `tl_token.tl` (the `main`-less module pattern from #44/#116).
(import "tl_token.tl")

;; ASCII code point of a char, e.g. the digit char `7` -> 55.
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char (ASCII '0'..'9' == 48..57).
(define (is-digit [c : char]) : bool
  (and (>= (code c) 48) (<= (code c) 57)))

;; `c` is an ASCII letter (A-Z == 65..90, a-z == 97..122).
(define (is-alpha [c : char]) : bool
  (let ([k : i64 (code c)])
    (or (and (>= k 65) (<= k 90))
        (and (>= k 97) (<= k 122)))))

;; `c` is one of TypeLisp's symbol punctuation chars - the non-alphanumeric
;; characters that may appear in a symbol/operator name:
;;   `-` 45  `+` 43  `*` 42  `/` 47  `?` 63  `!` 33  `>` 62  `<` 60  `=` 61
;;   `_` 95
;; This is what makes `+`, `<=`, `string->int`, and `array-set!` all lex as one
;; `TSym` rather than as separate operator tokens.
(define (is-symbol-punct [c : char]) : bool
  (let ([k : i64 (code c)])
    (or (= k 45)
        (or (= k 43)
            (or (= k 42)
                (or (= k 47)
                    (or (= k 63)
                        (or (= k 33)
                            (or (= k 62)
                                (or (= k 60)
                                    (or (= k 61)
                                        (= k 95))))))))))))

;; `c` may appear in a symbol: a letter, a digit, or a symbol-punctuation char.
;; A symbol run is the maximal span of these starting at a non-digit symbol char.
(define (is-symbol-char [c : char]) : bool
  (or (is-alpha c) (or (is-digit c) (is-symbol-punct c))))

;; `c` is ASCII whitespace: space (32), tab (9), or newline (10).
(define (is-space [c : char]) : bool
  (let ([k : i64 (code c)])
    (or (= k 32) (or (= k 9) (= k 10)))))

;; Return the end index (exclusive) of the digit run that starts at `start` in
;; `src`. `n` is the source length. The bounds check is kept outside the
;; `string-ref` (boolean `and` is not a short-circuit guard in lowered code).
(define (scan-int-end [src : String] [start : i64] [n : i64]) : i64
  (let ([j : i64 start]
        [keep : bool true])
    (begin
      (while keep
        (if (< j n)
            (if (is-digit (string-ref src j))
                (set! j (+ j 1))
                (set! keep false))
            (set! keep false)))
      j)))

;; Return the end index (exclusive) of the symbol run that starts at `start` in
;; `src`. Same bounds-check discipline as `scan-int-end`.
(define (scan-symbol-end [src : String] [start : i64] [n : i64]) : i64
  (let ([j : i64 start]
        [keep : bool true])
    (begin
      (while keep
        (if (< j n)
            (if (is-symbol-char (string-ref src j))
                (set! j (+ j 1))
                (set! keep false))
            (set! keep false)))
      j)))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. A `(` / `)` is a single-char paren token; a digit run is sliced
;; with `substring` and parsed with `string->int` into a `(TInt ...)`; a symbol
;; run is sliced with `substring` into a `(TSym ...)`; an unexpected char aborts
;; via `panic`. The terminating `TEnd` is recorded so a parser's cursor always
;; has a sentinel to stop on.
(define (lex-into [src : String] [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [n : i64 (string-length src)]
        [count : i64 0])
    (begin
      (while (< i n)
        (let ([c : char (string-ref src i)])
          (if (is-space c)
              (set! i (+ i 1))
              (if (= (code c) 40)        ; '('
                  (begin
                    (array-set! toks count TLParen)
                    (set! count (+ count 1))
                    (set! i (+ i 1)))
                  (if (= (code c) 41)    ; ')'
                      (begin
                        (array-set! toks count TRParen)
                        (set! count (+ count 1))
                        (set! i (+ i 1)))
                      (if (is-digit c)
                          ;; A digit run -> one TInt, parsed from its substring.
                          (let ([end : i64 (scan-int-end src i n)])
                            (begin
                              (array-set! toks count
                                (TInt (string->int (substring src i (- end i)))))
                              (set! count (+ count 1))
                              (set! i end)))
                          (if (is-symbol-char c)
                              ;; A symbol run -> one TSym carrying its lexeme.
                              (let ([end : i64 (scan-symbol-end src i n)])
                                (begin
                                  (array-set! toks count
                                    (TSym (substring src i (- end i))))
                                  (set! count (+ count 1))
                                  (set! i end)))
                              (begin
                                (panic "lexer: unexpected character")
                                (set! i (+ i 1))))))))))
      ;; A real lexer terminates the stream; record the sentinel too.
      (array-set! toks count TEnd)
      count)))

;; `lex : (-> String (Array Token))` - the public entry point. Size the token
;; array by an upper bound (every char yields at most one token, plus the TEnd
;; sentinel), lex into it, then return that exact array. The trailing TEnd marks
;; the logical end even though the backing array may be larger.
(define (lex [src : String]) : (Array Token)
  (let ([toks : (Array Token) (make-array Token (+ (string-length src) 1))])
    (begin
      (lex-into src toks)
      toks)))

;; Count the TSym tokens in `toks` up to and including the TEnd sentinel: walk
;; the array, tallying each token whose tag is `tag-sym`, and stop at TEnd. An
;; observable, count-based result that depends on the symbol classification.
(define (count-syms [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [syms : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : i64 (token-tag (array-ref toks i))])
          (if (= t (tag-end))
              (set! keep false)
              (begin
                (if (= t (tag-sym))
                    (set! syms (+ syms 1))
                    (set! syms syms))
                (set! i (+ i 1))))))
      syms)))

;; Lex a real TypeLisp s-expression sample and return an observable count.
;; For "(define (f x) (+ x 1))" the token stream is:
;;   (  define  (  f  x  )  (  +  x  1  )  )  End
;; i.e. tokens: TLParen TSym(define) TLParen TSym(f) TSym(x) TRParen TLParen
;;              TSym(+) TSym(x) TInt(1) TRParen TRParen  [+ TEnd sentinel].
;; The symbols are: define f x + x  => 5 TSym tokens. `main` returns that count
;; (5), an observable result an execution test can assert as the exit code,
;; depending on both the lexing loop and the symbol classification.
(define (main) : i64
  (count-syms (lex "(define (f x) (+ x 1))")))
