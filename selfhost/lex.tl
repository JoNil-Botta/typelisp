;; lex.tl - The TypeLisp-syntax (s-expression) lexer factored out as a
;; `main`-less, importable module (refs #27/#44).
;;
;; --------------------------------------------------------------------------
;; Why this module exists (the module signal for the reader, refs #44/#81).
;; --------------------------------------------------------------------------
;; `lexer.tl` is the *demo* program for the s-expression lexer: it carries a
;; `main` that lexes a sample and tallies its symbols. But the next front-end
;; component - the s-expression *reader* in `reader.tl` - wants to REUSE the
;; lexer's `lex : (-> String (Array Token))` rather than re-derive it, and it
;; carries its own `main` (read tokens into a recursive `Sexpr` tree, fold it).
;;
;; The module loader (#44) is whole-program: it concatenates every imported
;; module's declarations into a single program, then runs the unchanged
;; `typecheck -> lower -> codegen` pipeline. So two modules that both declare a
;; `main` and are loaded together produce a duplicate `main` symbol - the known
;; module limitation. Importing `lexer.tl` (which HAS a `main`) into the
;; reader (which also needs a `main`) would clash.
;;
;; The fix is this `main`-less module: it holds the lexer's scanners and the
;; public `lex` entry, `(import)`s the shared `main`-less `token.tl` token
;; model, and declares NO `main`. The reader `(import "lex.tl")`s it and gets
;; `lex` + `Token` (transitively `token.tl`) across the import boundary, and
;; the concatenated program has exactly one `main` (the reader's). `lexer.tl`
;; stays as the lexer's standalone demo. This mirrors how `calc.tl` imports the
;; `main`-less `token.tl`: a `main`-less module is the unit of reuse, a
;; `main`-bearing file is a runnable demo.

;; The shared token model: the `Token` enum and the `token-tag` / `token-int` /
;; `token-sym` / `token-str` / `token-char` accessors and tag constants.
;; Resolved relative to this file, so it finds the co-located `token.tl`. This
;; is a transitive import: the reader imports this module, which imports
;; `token.tl`; the loader's post-order DFS loads `token.tl` first, then this
;; module, then the reader.
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
;; starts at `start` (i.e. just AFTER the opening quote). `n` is the source
;; length. Scans forward until a `"` is found and returns its index.
;; Running off the end of the source with no closing quote is an unterminated
;; string literal and aborts via `panic`, exactly as a real lexer reports it.
;; NO escape handling: a `\"` is NOT treated as an escaped quote here - escape
;; sequences are deferred (see the module header note). Same bounds-check
;; discipline as the other scanners (the `< j n` guard is kept outside the
;; `string-ref`).
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

;; Return the index of the end-of-line that ends a `;` line comment whose body
;; starts at `start`. `n` is the source length. Scans forward until a newline
;; or the end of the source, returning that index (the newline is
;; left for the main loop's whitespace skip to consume). Same bounds-check
;; discipline as the other scanners.
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
;; opens a string literal whose inner text is sliced with `substring` into a
;; `(TStr ...)` (closing quote skipped); a `#` opens a char literal whose
;; payload is recorded as `(TChar ...)`; a `;` opens a line comment that is
;; skipped to end-of-line and emits NO token; a symbol run is sliced with
;; `substring` into a `(TSym ...)`; an unexpected char aborts via `panic`. The
;; `"`, `#`, and `;` cases are tested BEFORE the symbol path so they are not
;; lexed as symbol chars. The terminating `TEnd` is recorded so a parser's cursor
;; always has a sentinel to stop on.
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
                          ;; Inner text runs from just after the opening quote to
                          ;; the closing quote; slice it into a TStr and skip the
                          ;; closing quote. NO escape handling (deferred).
                          (let ([start : i64 (+ i 1)])
                            (let ([end : i64 (scan-str-end src start n)])
                              (begin
                                (array-set! toks count
                                  (TStr (substring src start (- end start))))
                                (set! count (+ count 1))
                                (set! i (+ end 1)))))
                          (if (= c #;')  ; ';' - a line comment
                              ;; Skip to end-of-line; emit no token. The newline
                              ;; (if any) is left for the whitespace skip.
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
