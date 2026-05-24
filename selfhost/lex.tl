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
;; The fix is this `main`-less module: it holds the lexer's scanners, the
;; recoverable `lex-result` entry, the legacy `lex` wrapper, `(import)`s the
;; shared `main`-less `token.tl` token model, and declares NO `main`. The reader
;; `(import "lex.tl")`s it and gets `lex` + `Token` (transitively `token.tl`)
;; across the import boundary, and the concatenated program has exactly one
;; `main` (the reader's). `lexer.tl`
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

(defenum ResultTokens
  (OkTokens (Array Token))
  (ErrTokens String))

(defenum ResultSpannedTokens
  (OkSpannedTokens (Array SpannedToken))
  (ErrSpannedTokens SourceError))

(defenum ResultLexI64
  (OkLexI64 i64)
  (ErrLexI64 String))

(defenum ResultLexCheck
  (OkLexCheck i64)
  (ErrLexCheck SourceError))

(defenum ResultLexChar
  (OkLexChar char)
  (ErrLexChar String))

(define (lex-ok? [message : String]) : bool
  (string-eq message ""))

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
;; length. Scans forward until a `"` is found and returns its index. Running off
;; the end returns a recoverable lexer error. NO escape handling: a `\"` is NOT
;; treated as an escaped quote here - escape sequences are deferred (see the
;; module header note). Same bounds-check discipline as the other scanners.
(define (scan-str-end-result [src : String] [start : i64] [n : i64]) : ResultLexI64
  (let ([j : i64 start]
        [keep : bool true]
        [message : String ""])
    (begin
      (while keep
        (if (< j n)
            (if (= (string-ref src j) #"')
                (set! keep false)
                (set! j (+ j 1)))
            (begin
              (set! message "lexer: unterminated string literal")
              (set! keep false))))
      (if (lex-ok? message)
          (OkLexI64 j)
          (ErrLexI64 message)))))

(define (scan-str-end [src : String] [start : i64] [n : i64]) : i64
  (match (scan-str-end-result src start n)
    [(OkLexI64 end) end]
    [(ErrLexI64 message)
     (begin
       (panic message)
       n)]))

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

;; Return an empty string when a character literal has a closing `'` at `idx`,
;; otherwise return the recoverable lexer diagnostic.
(define (char-close-error [src : String] [idx : i64] [n : i64]) : String
  (if (< idx n)
      (if (= (string-ref src idx) #'')
          ""
          "lexer: expected ' after character")
      "lexer: unterminated character literal"))

(define (require-char-close [src : String] [idx : i64] [n : i64]) : unit
  (let ([message : String (char-close-error src idx n)])
    (if (lex-ok? message)
        unit
        (panic message))))

;; Map a multi-letter `#\name'` character literal to its character payload.
(define (named-char-result [name : String]) : ResultLexChar
  (if (string-eq name "space")
      (OkLexChar #\space')
      (if (string-eq name "newline")
          (OkLexChar #\newline')
          (if (string-eq name "tab")
              (OkLexChar #\tab')
              (if (string-eq name "return")
                  (OkLexChar #\return')
                  (if (string-eq name "nul")
                      (OkLexChar #\nul')
                      (ErrLexChar "lexer: unknown named character literal")))))))

(define (named-char [name : String]) : char
  (match (named-char-result name)
    [(OkLexChar c) c]
    [(ErrLexChar message)
     (begin
       (panic message)
       #\nul')]))

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
(define (char-literal-value-result [src : String] [i : i64] [n : i64]) : ResultLexChar
  (if (< (+ i 1) n)
      (if (= (string-ref src (+ i 1)) #\\')
          (let ([start : i64 (+ i 2)])
            (if (< start n)
                (if (starts-named-char src start n)
                    (let ([end : i64 (scan-char-name-end src start n)])
                      (let ([message : String (char-close-error src end n)])
                        (if (lex-ok? message)
                            (named-char-result (substring src start (- end start)))
                            (ErrLexChar message))))
                    (let ([message : String (char-close-error src (+ start 1) n)])
                      (if (lex-ok? message)
                          (OkLexChar (escaped-char (string-ref src start)))
                          (ErrLexChar message))))
                (ErrLexChar "lexer: unterminated character literal")))
          (let ([message : String (char-close-error src (+ i 2) n)])
            (if (lex-ok? message)
                (OkLexChar (string-ref src (+ i 1)))
                (ErrLexChar message))))
      (ErrLexChar "lexer: unterminated character literal")))

(define (char-literal-value [src : String] [i : i64] [n : i64]) : char
  (match (char-literal-value-result src i n)
    [(OkLexChar c) c]
    [(ErrLexChar message)
     (begin
       (panic message)
       #\nul')]))

;; Index just after the closing `'` for a char literal beginning at `i`.
(define (char-literal-end-result [src : String] [i : i64] [n : i64]) : ResultLexI64
  (if (< (+ i 1) n)
      (if (= (string-ref src (+ i 1)) #\\')
          (let ([start : i64 (+ i 2)])
            (if (< start n)
                (if (starts-named-char src start n)
                    (let ([end : i64 (scan-char-name-end src start n)])
                      (let ([message : String (char-close-error src end n)])
                        (if (lex-ok? message)
                            (OkLexI64 (+ end 1))
                            (ErrLexI64 message))))
                    (let ([message : String (char-close-error src (+ start 1) n)])
                      (if (lex-ok? message)
                          (OkLexI64 (+ start 2))
                          (ErrLexI64 message))))
                (ErrLexI64 "lexer: unterminated character literal")))
          (let ([message : String (char-close-error src (+ i 2) n)])
            (if (lex-ok? message)
                (OkLexI64 (+ i 3))
                (ErrLexI64 message))))
      (ErrLexI64 "lexer: unterminated character literal")))

(define (char-literal-end [src : String] [i : i64] [n : i64]) : i64
  (match (char-literal-end-result src i n)
    [(OkLexI64 end) end]
    [(ErrLexI64 message)
     (begin
       (panic message)
       n)]))

(define (lex-check-char-end [src : String] [i : i64] [n : i64]) : ResultLexI64
  (match (char-literal-value-result src i n)
    [(OkLexChar _) (char-literal-end-result src i n)]
    [(ErrLexChar message) (ErrLexI64 message)]))

(define (lex-check-step [src : String] [i : i64] [n : i64]) : ResultLexI64
  (let ([c : char (string-ref src i)])
    (if (is-space c)
        (OkLexI64 (+ i 1))
        (if (or (= c #(') (= c #['))
            (OkLexI64 (+ i 1))
            (if (or (= c #)') (= c #]'))
                (OkLexI64 (+ i 1))
                (if (= c #"')
                    (let ([start : i64 (+ i 1)])
                      (match (scan-str-end-result src start n)
                        [(OkLexI64 end) (OkLexI64 (+ end 1))]
                        [(ErrLexI64 message) (ErrLexI64 message)]))
                    (if (= c #;')
                        (OkLexI64 (scan-comment-end src (+ i 1) n))
                        (if (= c ##')
                            (lex-check-char-end src i n)
                            (if (is-digit c)
                                (OkLexI64 (scan-int-end src i n))
                                (if (is-symbol-char c)
                                    (OkLexI64 (scan-symbol-end src i n))
                                    (ErrLexI64 "lexer: unexpected character")))))))))))

(define (lex-check-spanned [src : String]) : ResultLexCheck
  (let ([i : i64 0]
        [n : i64 (string-length src)]
        [message : String ""]
        [err-pos : i64 0])
    (begin
      (while (and (< i n) (lex-ok? message))
        (match (lex-check-step src i n)
          [(OkLexI64 next) (set! i next)]
          [(ErrLexI64 err)
           (begin
             (set! message err)
             (set! err-pos i)
             (set! i n))]))
      (if (lex-ok? message)
          (OkLexCheck i)
          (ErrLexCheck (SourceError message (source-point-span src err-pos)))))))

(define (lex-check [src : String]) : ResultLexI64
  (match (lex-check-spanned src)
    [(OkLexCheck end) (OkLexI64 end)]
    [(ErrLexCheck err) (ErrLexI64 (source-error-message err))]))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. Compatibility callers use this panic-on-error path through
;; `lex`; the recoverable `lex-result` validates with `lex-check` first.
(define (lex-spanned-into [src : String] [toks : (Array SpannedToken)]) : i64
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
                    (array-set! toks count
                      (SpannedToken TLParen (source-span src i (+ i 1))))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))
                  (if (or (= c #)') (= c #]'))
                      (begin
                        (array-set! toks count
                          (SpannedToken TRParen (source-span src i (+ i 1))))
                        (set! count (+ count 1))
                        (set! i (+ i 1)))
                      (if (= c #"')  ; '"' - a string literal
                          (let ([start : i64 (+ i 1)])
                            (let ([end : i64 (scan-str-end src start n)])
                              (begin
                                (array-set! toks count
                                  (SpannedToken
                                    (TStr (substring src start (- end start)))
                                    (source-span src i (+ end 1))))
                                (set! count (+ count 1))
                                (set! i (+ end 1)))))
                          (if (= c #;')  ; ';' - a line comment
                              (set! i (scan-comment-end src (+ i 1) n))
                              (if (= c ##')  ; '#' - a char literal
                                  (let ([value : char (char-literal-value src i n)])
                                    (let ([end : i64 (char-literal-end src i n)])
                                      (begin
                                        (array-set! toks count
                                          (SpannedToken (TChar value) (source-span src i end)))
                                        (set! count (+ count 1))
                                        (set! i end))))
                                  (if (is-digit c)
                                      (let ([end : i64 (scan-int-end src i n)])
                                        (begin
                                          (array-set! toks count
                                            (SpannedToken
                                              (TInt (string->int (substring src i (- end i))))
                                              (source-span src i end)))
                                          (set! count (+ count 1))
                                          (set! i end)))
                                      (if (is-symbol-char c)
                                          (let ([end : i64 (scan-symbol-end src i n)])
                                            (begin
                                              (array-set! toks count
                                                (SpannedToken
                                                  (TSym (substring src i (- end i)))
                                                  (source-span src i end)))
                                              (set! count (+ count 1))
                                              (set! i end)))
                                          (begin
                                            (panic "lexer: unexpected character")
                                            (set! i (+ i 1)))))))))))))
      (array-set! toks count (SpannedToken TEnd (source-point-span src n)))
      count)))

(define (copy-spanned-tokens [spanned : (Array SpannedToken)] [toks : (Array Token)]) : i64
  (let ([i : i64 0]
        [keep : bool true])
    (begin
      (while keep
        (let ([tok : Token (spanned-token-token (array-ref spanned i))])
          (begin
            (array-set! toks i tok)
            (if (= (token-tag tok) (tag-end))
                (set! keep false)
                (set! i (+ i 1))))))
      i)))

(define (lex-into [src : String] [toks : (Array Token)]) : i64
  (let ([spanned : (Array SpannedToken) (make-array SpannedToken (+ (string-length src) 1))])
    (begin
      (lex-spanned-into src spanned)
      (copy-spanned-tokens spanned toks))))

;; `lex : (-> String (Array Token))` - the public entry point. Size the token
;; array by an upper bound (every char yields at most one token, plus the TEnd
;; sentinel), lex into it, then return that exact array. The trailing TEnd marks
;; the logical end even though the backing array may be larger.
(define (lex-spanned-result [src : String]) : ResultSpannedTokens
  (match (lex-check-spanned src)
    [(OkLexCheck _)
     (let ([toks : (Array SpannedToken) (make-array SpannedToken (+ (string-length src) 1))])
       (begin
         (lex-spanned-into src toks)
         (OkSpannedTokens toks)))]
    [(ErrLexCheck err) (ErrSpannedTokens err)]))

(define (lex-result [src : String]) : ResultTokens
  (match (lex-spanned-result src)
    [(OkSpannedTokens spanned)
     (let ([toks : (Array Token) (make-array Token (+ (string-length src) 1))])
       (begin
         (copy-spanned-tokens spanned toks)
         (OkTokens toks)))]
    [(ErrSpannedTokens err) (ErrTokens (source-error-message err))]))

(define (lex-spanned [src : String]) : (Array SpannedToken)
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) toks]
    [(ErrSpannedTokens err)
     (begin
       (panic (source-error-message err))
       (make-array SpannedToken 1))]))

(define (lex [src : String]) : (Array Token)
  (match (lex-result src)
    [(OkTokens toks) toks]
    [(ErrTokens message)
     (begin
       (panic message)
       (make-array Token 1))]))
