;; lexer.tl - A lexer for TypeLisp's OWN s-expression syntax, written in
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
;; collapse to: `(` `)` integer symbol end (see the imported `token.tl`).
;;
;; The scan loop is the shape of a real lexer: a cursor over the input, a
;; whitespace skip, single-char paren tokens, a digit run sliced into a
;; `(TInt (string->int ...))`, and a symbol run sliced into a `(TSym ...)` with
;; `substring`, string literals, char literals, and line comments. An unexpected
;; character aborts via the `panic` builtin (#45), exactly as a real lexer
;; reports malformed input.
;;
;; String literals (`"..."`), char literals (`#x'` / `#\x'`), and `;` line
;; comments are now lexed too: a `"` opens a string whose inner text is sliced
;; into a `(TStr ...)` (closing quote skipped), a `#` opens a character literal
;; recorded as `(TChar ...)`, and a `;` skips the rest of the line, emitting no
;; token.
;;
;; Deferred - current scope boundaries, recorded as self-hosting signal:
;;   - String-literal ESCAPES (`\"`, `\n`, ...): the inner text is sliced raw,
;;     so `\"` does NOT continue the string and `\n` is two literal chars.
;;   - Keyword classification: keywords are lexed as plain `TSym` tokens here; a
;;     later pass (or the parser) distinguishes `define`/`let`/... from names.

;; The shared token model: the `Token` enum and the token accessors/tag
;; constants. Resolved relative to this file, so it finds the co-located
;; `token.tl` (the `main`-less module pattern from #44/#116).
(import "token.tl")

;; Numeric code point of a char, used only when a code value is intentionally
;; observed (for example in the lexer demo's character-code checksum).
(define (code [c : char]) : i64
  (cast c : i64))

;; `c` is a decimal digit char.
(define (is-digit [c : char]) : bool
  (and (>= c #0') (<= c #9')))

;; `c` is an ASCII letter.
(define (is-alpha [c : char]) : bool
  (or (and (>= c #A') (<= c #Z'))
      (and (>= c #a') (<= c #z'))))

;; `c` is one of TypeLisp's symbol punctuation chars - the non-alphanumeric
;; characters that may appear in a symbol/operator name:
;;   `-` `+` `*` `/` `?` `!` `>` `<` `=` `:` `_`
;; This is what makes `+`, `<=`, `string->int`, and `array-set!` all lex as one
;; `TSym` rather than as separate operator tokens.
(define (is-symbol-punct [c : char]) : bool
  (or (= c #-')
      (or (= c #+')
          (or (= c #*')
              (or (= c #/')
                  (or (= c #?')
                      (or (= c #!')
                          (or (= c #>')
                              (or (= c #<')
                                  (or (= c #=')
                                      (or (= c #:')
                                          (= c #_'))))))))))))

;; `c` may appear in a symbol: a letter, a digit, or a symbol-punctuation char.
;; A symbol run is the maximal span of these starting at a non-digit symbol char.
(define (is-symbol-char [c : char]) : bool
  (or (is-alpha c) (or (is-digit c) (is-symbol-punct c))))

;; `c` is ASCII whitespace.
(define (is-space [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (= c #\newline'))))

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

;; Return the index of the closing `"` of a string literal whose inner text
;; starts at `start` (just AFTER the opening quote). Scans forward to the next
;; `"`; running off the end is an unterminated literal and aborts via
;; `panic`. NO escape handling (deferred). Same bounds-check discipline.
(define (scan-str-end [src : String] [start : i64] [n : i64]) : i64
  (let ([j : i64 start]
        [keep : bool true])
    (begin
      (while keep
        (if (< j n)
            (if (= (string-ref src j) #"')
                (set! keep false)
                (set! j (+ j 1)))
            (begin
              (panic "lexer: unterminated string literal")
              (set! keep false))))
      j)))

;; Return the end-of-line index that ends a `;` line comment whose body starts
;; at `start`: the next newline or the end of the source (the newline
;; is left for the whitespace skip). Same bounds-check discipline.
(define (scan-comment-end [src : String] [start : i64] [n : i64]) : i64
  (let ([j : i64 start]
        [keep : bool true])
    (begin
      (while keep
        (if (< j n)
            (if (= (string-ref src j) #\newline')
                (set! keep false)
                (set! j (+ j 1)))
            (set! keep false)))
      j)))

;; A named character literal starts after `#\` only when the first TWO chars are
;; alphabetic. This matches the Rust lexer and keeps `#\n'` as the newline escape
;; instead of trying to read the one-letter name `n`.
(define (starts-named-char [src : String] [start : i64] [n : i64]) : bool
  (if (< (+ start 1) n)
      (if (is-alpha (string-ref src start))
          (is-alpha (string-ref src (+ start 1)))
          false)
      false))

;; Return the end index (exclusive) of a named char's alphabetic name.
(define (scan-char-name-end [src : String] [start : i64] [n : i64]) : i64
  (let ([j : i64 start]
        [keep : bool true])
    (begin
      (while keep
        (if (< j n)
            (if (is-alpha (string-ref src j))
                (set! j (+ j 1))
                (set! keep false))
            (set! keep false)))
      j)))

;; Require a closing `'` at `idx`; malformed char literals abort like other
;; lexer errors.
(define (require-char-close [src : String] [idx : i64] [n : i64]) : unit
  (if (< idx n)
      (if (= (string-ref src idx) #'')
          unit
          (panic "lexer: expected ' after character"))
      (panic "lexer: unterminated character literal")))

;; Map a multi-letter `#\name'` character literal to its character payload.
(define (named-char [name : String]) : char
  (if (string-eq name "space")
      #\space'
      (if (string-eq name "newline")
          #\newline'
          (if (string-eq name "tab")
              #\tab'
              (if (string-eq name "return")
                  #\return'
                  (if (string-eq name "nul")
                      #\nul'
                      (begin
                        (panic "lexer: unknown named character literal")
                        #\nul')))))))

;; Map single-character escapes after `#\`; unknown escapes read as the literal
;; character, matching stage0 (`#\a'` is `a`).
(define (escaped-char [c : char]) : char
  (if (= c #n')
      #\newline'
      (if (= c #t')
          #\tab'
          (if (= c #r')
              #\return'
              (if (= c #0')
                  #\nul'
                  c)))))

;; Character payload for a literal beginning at `i`, where `src[i]` is `#`.
(define (char-literal-value [src : String] [i : i64] [n : i64]) : char
  (if (< (+ i 1) n)
      (if (= (string-ref src (+ i 1)) #\\')
          (let ([start : i64 (+ i 2)])
            (if (< start n)
                (if (starts-named-char src start n)
                    (let ([end : i64 (scan-char-name-end src start n)])
                      (begin
                        (require-char-close src end n)
                        (named-char (substring src start (- end start)))))
                    (begin
                      (require-char-close src (+ start 1) n)
                      (escaped-char (string-ref src start))))
                (begin
                  (panic "lexer: unterminated character literal")
                  #\nul')))
          (begin
            (require-char-close src (+ i 2) n)
            (string-ref src (+ i 1))))
      (begin
        (panic "lexer: unterminated character literal")
        #\nul')))

;; Index just after the closing `'` for a char literal beginning at `i`.
(define (char-literal-end [src : String] [i : i64] [n : i64]) : i64
  (if (< (+ i 1) n)
      (if (= (string-ref src (+ i 1)) #\\')
          (let ([start : i64 (+ i 2)])
            (if (< start n)
                (if (starts-named-char src start n)
                    (let ([end : i64 (scan-char-name-end src start n)])
                      (begin
                        (require-char-close src end n)
                        (+ end 1)))
                    (begin
                      (require-char-close src (+ start 1) n)
                      (+ start 2)))
                (begin
                  (panic "lexer: unterminated character literal")
                  n)))
          (begin
            (require-char-close src (+ i 2) n)
            (+ i 3)))
      (begin
        (panic "lexer: unterminated character literal")
        n)))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. A `(` / `[` or `)` / `]` is a single-char paren token; a digit run is sliced
;; with `substring` and parsed with `string->int` into a `(TInt ...)`; a `"`
;; opens a string literal whose inner text is sliced into a `(TStr ...)`
;; (closing quote skipped); a `#` opens a char literal whose payload is recorded
;; as `(TChar ...)`; a `;` opens a line comment skipped to end-of-line (NO
;; token); a symbol run is sliced with `substring` into a `(TSym ...)`; an
;; unexpected char aborts via `panic`. The `"`, `#`, and `;` cases are tested
;; BEFORE the symbol path so they are not lexed as symbol chars. The terminating
;; `TEnd` is recorded so a parser's cursor always has a sentinel to stop on.
(define (lex-into [src : String] [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [n : i64 (string-length src)]
        [count : i64 0])
    (begin
      (while (< i n)
        (let ([c : char (string-ref src i)])
          (if (is-space c)
              (set! i (+ i 1))
              (if (or (= c #(') (= c #['))
                  (begin
                    (array-set! toks count TLParen)
                    (set! count (+ count 1))
                    (set! i (+ i 1)))
                  (if (or (= c #)') (= c #]'))
                      (begin
                        (array-set! toks count TRParen)
                        (set! count (+ count 1))
                        (set! i (+ i 1)))
                      (if (= c #"')  ; '"' - a string literal
                          (let ([start : i64 (+ i 1)])
                            (let ([end : i64 (scan-str-end src start n)])
                              (begin
                                (array-set! toks count
                                  (TStr (substring src start (- end start))))
                                (set! count (+ count 1))
                                (set! i (+ end 1)))))
                          (if (= c #;')  ; ';' - a line comment
                              (set! i (scan-comment-end src (+ i 1) n))
                              (if (= c ##')  ; '#' - a char literal
                                  (let ([value : char (char-literal-value src i n)])
                                    (let ([end : i64 (char-literal-end src i n)])
                                      (begin
                                        (array-set! toks count (TChar value))
                                        (set! count (+ count 1))
                                        (set! i end))))
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
                                            (set! i (+ i 1)))))))))))))
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

;; Count the TStr tokens in `toks` up to the TEnd sentinel: same walk, tallying
;; each token whose tag is `tag-str`. Depends on the string-literal lexing.
(define (count-strs [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [strs : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : i64 (token-tag (array-ref toks i))])
          (if (= t (tag-end))
              (set! keep false)
              (begin
                (if (= t (tag-str))
                    (set! strs (+ strs 1))
                    (set! strs strs))
                (set! i (+ i 1))))))
      strs)))

;; Count the TChar tokens in `toks` up to the TEnd sentinel: same walk, tallying
;; each token whose tag is `tag-char`. Depends on char literal lexing and keeps
;; chars observably distinct from symbols, ints, and strings.
(define (count-chars [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [chars : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : i64 (token-tag (array-ref toks i))])
          (if (= t (tag-end))
              (set! keep false)
              (begin
                (if (= t (tag-char))
                    (set! chars (+ chars 1))
                    (set! chars chars))
                (set! i (+ i 1))))))
      chars)))

;; Sum character code points in TChar tokens so the demo observes decoded
;; single, escaped, and named character values, not just token tags.
(define (sum-char-codes [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [total : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([t : Token (array-ref toks i)])
          (if (= (token-tag t) (tag-end))
              (set! keep false)
              (begin
                (if (= (token-tag t) (tag-char))
                    (set! total (+ total (code (token-char t))))
                    (set! total total))
                (set! i (+ i 1))))))
      total)))

;; Total token count (every token before the TEnd sentinel). Depends on the
;; comment skip producing NO token and a string literal being exactly ONE token.
(define (count-tokens [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (if (= (token-tag (array-ref toks i)) (tag-end))
            (set! keep false)
            (set! i (+ i 1))))
      i)))

;; Lex a real TypeLisp s-expression sample exercising string-literal,
;; char-literal, and line-comment scanners, and return an observable count. The
;; source is
;;   (foo "hi" #x' #\n' #\space' #\newline' 42) ; c
;;   (bar)
;; built from an escaped string literal. It tokenizes into 12 tokens: the prior
;; string/comment witness plus four TChar literals. The decoded char code sum is
;; 172 (`x` 120 + newline 10 + space 32 + named newline 10). `main` returns total
;; tokens (12) + TStr count (1) + TChar count (4) when that value sum matches,
;; for an observable exit code of 17.
(define (main) : i64
  (let ([toks : (Array Token)
          (lex "(foo \"hi\" #x' #\\n' #\\space' #\\newline' 42) ; c\n(bar)")])
    (+ (count-tokens toks)
       (+ (count-strs toks)
          (if (= (sum-char-codes toks) 172)
              (count-chars toks)
              0)))))
