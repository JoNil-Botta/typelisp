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
;; `token-sym` / `token-str` / `token-char` / `token-float` accessors and tag
;; constants.
;; Resolved relative to this file, so it finds the co-located `token.tl`. This
;; is a transitive import: the reader imports this module, which imports
;; `token.tl`; the loader's post-order DFS loads `token.tl` first, then this
;; module, then the reader.
(import "../stdlib/io.tl")

(import "token.tl")

(import "../stdlib/text_buf.tl")

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

(defenum ResultLexIntoSpanned
  (OkLexIntoSpanned i64)
  (ErrLexIntoSpanned SourceError))

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
  (or (and (>= c #A') (<= c #Z')) (and (>= c #a') (<= c #z'))))

;; `c` is one of TypeLisp's symbol punctuation chars - the non-alphanumeric
;; characters that may appear in a symbol/operator name:
;;   `-` `+` `*` `/` `%` `&` `?` `!` `>` `<` `=` `:` `_`
;; This is what makes `+`, `<=`, `string->int`, and `array-set!` all lex as one
;; `TSym` rather than as separate operator tokens.
(define (is-symbol-punct [c : char]) : bool
  (or
    (= c #-')
    (or
      (= c #+')
      (or
        (= c #*')
        (or
          (= c #/')
          (or
            (= c #?')
            (or
              (= c #!')
              (or
                (= c #>')
                (or
                  (= c #<')
                  (or
                    (= c #=')
                    (or
                      (= c #&')
                      (or (= c #:') (or (= c #_') (or (= c #.') (= c #%')))))))))))))))

;; `c` may appear in a symbol: a letter, a digit, or a symbol-punctuation char.
;; A symbol run is the maximal span of these starting at a non-digit symbol char.
(define (is-symbol-char [c : char]) : bool
  (let
    [code : i64 (cast c : i64)]
    (or
      (and (>= code 65) (<= code 90))
      (or
        (and (>= code 97) (<= code 122))
        (or
          (and (>= code 48) (<= code 57))
          (or
            (= code 33)
            (or
              (and (>= code 37) (<= code 38))
              (or
                (if (and (>= code 42) (<= code 47))
                  (not (= code 44))
                  false)
                (or
                  (= code 58)
                  (or
                    (and (>= code 60) (<= code 63))
                    (= code 95)))))))))))

;; `c` is ASCII whitespace.
(define (is-space [c : char]) : bool
  (or (= c #\space') (or (= c #\tab') (or (= c #\newline') (= c #\return')))))

;; Return the end index (exclusive) of the digit run that starts at `start` in
;; `src`. `n` is the source length. The bounds check is kept outside the
;; `string-ref` (boolean `and` is not a short-circuit guard in lowered code).
(define (scan-int-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (is-digit (string-ref src j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

;; A float token is an integer digit run followed by `.` and at least one
;; fractional digit. The literal text is carried through later selfhost stages.
(define (float-tail? [src : String] [int-end : i64] [n : i64]) : bool
  (if (< (+ int-end 1) n)
    (if (= (string-ref src int-end) #.')
      (is-digit (string-ref src (+ int-end 1)))
      false)
    false))

(define (scan-number-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [digits-start : i64 (number-digits-start src start)]
    [int-end : i64 (scan-int-end src digits-start n)]
    (if (float-tail? src int-end n)
      (scan-int-end src (+ int-end 1) n)
      int-end)))

(define (number-digits-start [src : String] [start : i64]) : i64
  (if (= (string-ref src start) #-')
    (+ start 1)
    start))

(define (number-float? [src : String] [start : i64] [n : i64]) : bool
  (float-tail? src (scan-int-end src (number-digits-start src start) n) n))

(define (negative-number-start? [src : String] [start : i64] [n : i64]) : bool
  (if (= (string-ref src start) #-')
    (if (< (+ start 1) n)
      (is-digit (string-ref src (+ start 1)))
      false)
    false))

;; Return the end index (exclusive) of the symbol run that starts at `start` in
;; `src`. Same bounds-check discipline as `scan-int-end`.
(define (scan-symbol-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
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
;; length. Scans forward until an unescaped `"` is found and returns its index.
;; Running off the end returns a recoverable lexer error. A backslash escapes the
;; following byte, so `\"` stays inside the string and a trailing backslash is an
;; unterminated string escape. Same bounds-check discipline as the other
;; scanners.
(define (scan-str-end-result [src : String] [start : i64] [n : i64]) : ResultLexI64
  (let
    [j : i64 start]
    [keep : bool true]
    [message : String ""]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (string-ref src j)]
            (if (= c #"')
              (set! keep false)
              (if (= c #\\')
                (if (< (+ j 1) n)
                  (set! j (+ j 2))
                  (begin
                    (set! message "lexer: unterminated string escape")
                    (set! keep false)))
                (set! j (+ j 1)))))
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

(define (string-escape-piece [src : String] [idx : i64]) : String
  (let
    [c : char (string-ref src idx)]
    (cond
      [(= c #n') "\n"]
      [(= c #t') "\t"]
      [(= c #r') "\r"]
      [(= c #\\') "\\"]
      [(= c #"') "\""]
      [else (substring src idx 1)])))

(define (unescape-string-literal [src : String] [start : i64] [end : i64]) : String
  (let
    [i : i64 start]
    [buf : TextBuf (text-buf-empty)]
    (begin
      (while (< i end)
        (let
          [c : char (string-ref src i)]
          (if (= c #\\')
            (if (< (+ i 1) end)
              (begin
                (set!
                  buf
                  (text-buf-append buf (string-escape-piece src (+ i 1))))
                (set! i (+ i 2)))
              (begin
                (set! buf (text-buf-append buf "\\"))
                (set! i (+ i 1))))
            (begin
              (set! buf (text-buf-append buf (substring src i 1)))
              (set! i (+ i 1))))))
      (text-buf-render buf))))

;; Return the index of the end-of-line that ends a `;` line comment whose body
;; starts at `start`. `n` is the source length. Scans forward until a newline
;; or the end of the source, returning that index (the newline is
;; left for the main loop's whitespace skip to consume). Same bounds-check
;; discipline as the other scanners.
(define (scan-comment-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
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
  (let
    [j : i64 start]
    [keep : bool true]
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
  (let
    [message : String (char-close-error src idx n)]
    (if (lex-ok? message)
      unit
      (panic message))))

;; Map a multi-letter `#\name'` character literal to its character payload.
(define (named-char-result [name : String]) : ResultLexChar
  (cond
    [(string-eq name "space") (OkLexChar #\space')]
    [(string-eq name "newline") (OkLexChar #\newline')]
    [(string-eq name "tab") (OkLexChar #\tab')]
    [(string-eq name "return") (OkLexChar #\return')]
    [(string-eq name "nul") (OkLexChar #\nul')]
    [else (ErrLexChar "lexer: unknown named character literal")]))

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
  (cond
    [(= c #n') #\newline']
    [(= c #t') #\tab']
    [(= c #r') #\return']
    [(= c #0') #\nul']
    [else c]))

;; Character payload for a literal beginning at `i`, where `src[i]` is `#`.
(define (char-literal-value-result [src : String] [i : i64] [n : i64]) : ResultLexChar
  (if (< (+ i 1) n)
    (if (= (string-ref src (+ i 1)) #\\')
      (let
        [start : i64 (+ i 2)]
        (if (< start n)
          (if (starts-named-char src start n)
            (let
              [end : i64 (scan-char-name-end src start n)]
              [message : String (char-close-error src end n)]
              (if (lex-ok? message)
                (named-char-result (substring src start (- end start)))
                (ErrLexChar message)))
            (let
              [message : String (char-close-error src (+ start 1) n)]
              (if (lex-ok? message)
                (OkLexChar (escaped-char (string-ref src start)))
                (ErrLexChar message))))
          (ErrLexChar "lexer: unterminated character literal")))
      (let
        [message : String (char-close-error src (+ i 2) n)]
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
      (let
        [start : i64 (+ i 2)]
        (if (< start n)
          (if (starts-named-char src start n)
            (let
              [end : i64 (scan-char-name-end src start n)]
              [message : String (char-close-error src end n)]
              (if (lex-ok? message)
                (OkLexI64 (+ end 1))
                (ErrLexI64 message)))
            (let
              [message : String (char-close-error src (+ start 1) n)]
              (if (lex-ok? message)
                (OkLexI64 (+ start 2))
                (ErrLexI64 message))))
          (ErrLexI64 "lexer: unterminated character literal")))
      (let
        [message : String (char-close-error src (+ i 2) n)]
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
  (let
    [c : char (string-ref src i)]
    (cond
      [(is-space c) (OkLexI64 (+ i 1))]
      [(or (= c #(') (= c #[')) (OkLexI64 (+ i 1))]
      [(or (= c #)') (= c #]')) (OkLexI64 (+ i 1))]
      [(or (= c #'') (= c #`')) (OkLexI64 (+ i 1))]
      [(= c #,')
        (if (< (+ i 1) n)
          (if (= (string-ref src (+ i 1)) #@')
            (OkLexI64 (+ i 2))
            (OkLexI64 (+ i 1)))
          (OkLexI64 (+ i 1)))]
      [(= c #"')
        (let
          [start : i64 (+ i 1)]
          (match (scan-str-end-result src start n)
            [(OkLexI64 end) (OkLexI64 (+ end 1))]
            [(ErrLexI64 message) (ErrLexI64 message)]))]
      [(= c #;') (OkLexI64 (scan-comment-end src (+ i 1) n))]
      [(= c ##') (lex-check-char-end src i n)]
      [(or (is-digit c) (negative-number-start? src i n))
        (OkLexI64 (scan-number-end src i n))]
      [(is-symbol-char c) (OkLexI64 (scan-symbol-end src i n))]
      [else (ErrLexI64 "lexer: unexpected character")])))

(define (lex-check-spanned [src : String]) : ResultLexCheck
  (let
    [i : i64 0]
    [n : i64 (string-length src)]
    [message : String ""]
    [err-pos : i64 0]
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
        (ErrLexCheck (source-error-at src err-pos message))))))

(define (lex-check [src : String]) : ResultLexI64
  (match (lex-check-spanned src)
    [(OkLexCheck end) (OkLexI64 end)]
    [(ErrLexCheck err) (ErrLexI64 (source-error-message err))]))

;; Lex `src`, recording each emitted `Token` value into `toks` (which must be
;; large enough to hold every token plus the TEnd sentinel) and returning the
;; token count. Compatibility callers use this panic-on-error path through
;; `lex`; recoverable callers use `lex-into-spanned-result` directly.
(define (lex-into [src : String] [toks : (Array Token)]) : i64
  (lex-into-spanned src toks (make-array i64 (array-length toks))))

;; Core scanner. Fills `toks` with the token stream and, in parallel, records
;; each token's starting byte index into `starts[count]` (#599). `lex-into`
;; passes a throwaway `starts` array so the plain token path is unchanged;
;; `lex-spanned-result` passes a real one and converts each start index to a
;; 1-based line/column. Returns the token count (excluding the trailing TEnd).
(define (lex-into-spanned-result
  [src : String]
  [toks : (Array Token)]
  [starts : (Array i64)]) : ResultLexIntoSpanned
  (let
    [i : i64 0]
    [n : i64 (string-length src)]
    [count : i64 0]
    [ok : bool true]
    [message : String ""]
    [err-pos : i64 0]
    (begin
      (while (and (< i n) ok)
        (let
          [c : char (string-ref src i)]
          (cond
            [(is-space c) (set! i (+ i 1))]
            [(= c #(')
              (begin
                (array-set! starts count i)
                (array-set! toks count TLParen)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c #[')
              (begin
                (array-set! starts count i)
                (array-set! toks count TLBracket)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c #)')
              (begin
                (array-set! starts count i)
                (array-set! toks count TRParen)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c #]')
              (begin
                (array-set! starts count i)
                (array-set! toks count TRBracket)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c #'')
              (begin
                (array-set! starts count i)
                (array-set! toks count TQuote)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c #`')
              (begin
                (array-set! starts count i)
                (array-set! toks count TBacktick)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c #,')
              (begin
                (array-set! starts count i)
                (if (< (+ i 1) n)
                  (if (= (string-ref src (+ i 1)) #@')
                    (begin
                      (array-set! toks count TCommaAt)
                      (set! i (+ i 2)))
                    (begin
                      (array-set! toks count TComma)
                      (set! i (+ i 1))))
                  (begin
                    (array-set! toks count TComma)
                    (set! i (+ i 1))))
                (set! count (+ count 1)))]
            [(= c #"')
              ; '"' - a string literal
              (let
                [start : i64 (+ i 1)]
                (match (scan-str-end-result src start n)
                  [(OkLexI64 end)
                    (begin
                      (array-set! starts count i)
                      (array-set!
                        toks
                        count
                        (TStr (unescape-string-literal src start end)))
                      (set! count (+ count 1))
                      (set! i (+ end 1)))]
                  [(ErrLexI64 err)
                    (begin
                      (set! ok false)
                      (set! message err)
                      (set! err-pos i))]))]
            [(= c #;')
              ; ';' - a line comment
              (set! i (scan-comment-end src (+ i 1) n))]
            [(= c ##')
              ; '#' - a char literal
              (match (char-literal-value-result src i n)
                [(OkLexChar value)
                  (match (char-literal-end-result src i n)
                    [(OkLexI64 end)
                      (begin
                        (array-set! starts count i)
                        (array-set! toks count (TChar value))
                        (set! count (+ count 1))
                        (set! i end))]
                    [(ErrLexI64 err)
                      (begin
                        (set! ok false)
                        (set! message err)
                        (set! err-pos i))])]
                [(ErrLexChar err)
                  (begin
                    (set! ok false)
                    (set! message err)
                    (set! err-pos i))])]
            [(or (is-digit c) (negative-number-start? src i n))
              (let
                [end : i64 (scan-number-end src i n)]
                (begin
                  (array-set! starts count i)
                  (if (number-float? src i n)
                    (array-set! toks count (TFloat (substring src i (- end i))))
                    (array-set!
                      toks
                      count
                      (TInt (string->int (substring src i (- end i))))))
                  (set! count (+ count 1))
                  (set! i end)))]
            [(is-symbol-char c)
              (let
                [end : i64 (scan-symbol-end src i n)]
                (begin
                  (array-set! starts count i)
                  (array-set! toks count (TSym (substring src i (- end i))))
                  (set! count (+ count 1))
                  (set! i end)))]
            [else
              (begin
                (set! ok false)
                (set! message "lexer: unexpected character")
                (set! err-pos i))])))
      (if ok
        (begin
          (array-set! starts count n)
          (array-set! toks count TEnd)
          (OkLexIntoSpanned count))
        (ErrLexIntoSpanned (source-error-at src err-pos message))))))

(define (lex-into-spanned
  [src : String]
  [toks : (Array Token)]
  [starts : (Array i64)]) : i64
  (match (lex-into-spanned-result src toks starts)
    [(OkLexIntoSpanned count) count]
    [(ErrLexIntoSpanned err)
      (begin
        (panic (source-error-message err))
        0)]))

;; `lex : (-> String (Array Token))` - the public entry point. Size the token
;; array by an upper bound (every char yields at most one token, plus the TEnd
;; sentinel), lex into it, then return that exact array. The trailing TEnd marks
;; the logical end even though the backing array may be larger.
(define (lex-result [src : String]) : ResultTokens
  (let
    [cap : i64 (+ (string-length src) 1)]
    [toks : (Array Token) (make-array Token cap)]
    [starts : (Array i64) (make-array i64 cap)]
    (match (lex-into-spanned-result src toks starts)
      [(OkLexIntoSpanned _) (OkTokens toks)]
      [(ErrLexIntoSpanned err) (ErrTokens (source-error-message err))])))

(define (lex [src : String]) : (Array Token)
  (match (lex-result src)
    [(OkTokens toks) toks]
    [(ErrTokens message)
      (begin
        (panic message)
        (make-array Token 1))]))

;; ---- Spanned token stream (#599) --------------------------------------------
;; A position-bearing token stream parallel to `lex`/`lex-result`. Each token is
;; paired with the 1-based line/column of its starting byte; the trailing `TEnd`
;; carries the position one past the last character. The plain `Token` path
;; above is untouched, so existing callers keep working.
;; 1-based line of byte index `idx` in `src`: 1 + the number of newlines before
;; `idx`.
(define (index-line [src : String] [idx : i64]) : i64
  (let
    [line : i64 1]
    [k : i64 0]
    (begin
      (while (< k idx)
        (begin
          (if (= (string-ref src k) #\newline')
            (set! line (+ line 1))
            unit)
          (set! k (+ k 1))))
      line)))

;; 1-based column of byte index `idx`: characters since the last newline (the
;; first column is 1).
(define (index-col [src : String] [idx : i64]) : i64
  (let
    [col : i64 1]
    [k : i64 0]
    (begin
      (while (< k idx)
        (begin
          (if (= (string-ref src k) #\newline')
            (set! col 1)
            (set! col (+ col 1)))
          (set! k (+ k 1))))
      col)))

(define (fill-spanned
  [src : String]
  [toks : (Array Token)]
  [starts : (Array i64)]
  [stoks : (Array SpannedToken)]
  [total : i64]) : unit
  (let
    [k : i64 0]
    [pos : i64 0]
    [line : i64 1]
    [col : i64 1]
    (while (< k total)
      (begin
        (let
          [at : i64 (array-ref starts k)]
          (begin
            (while (< pos at)
              (begin
                (if (= (string-ref src pos) #\newline')
                  (begin
                    (set! line (+ line 1))
                    (set! col 1))
                  (set! col (+ col 1)))
                (set! pos (+ pos 1))))
            (array-set! stoks k (SpannedToken (array-ref toks k) line col))))
        (set! k (+ k 1))))))

(define (source-error-at [src : String] [idx : i64] [message : String]) : SourceError
  (let
    [line : i64 (index-line src idx)]
    [col : i64 (index-col src idx)]
    (SourceError message (SourceSpan line col line col))))

;; `lex-spanned-result : (-> String ResultSpannedTokens)` - lex into a token +
;; start-index pair of arrays, then materialize `count + 1` spanned tokens
;; (including the trailing TEnd).
(define (lex-spanned-result [src : String]) : ResultSpannedTokens
  (let
    [cap : i64 (+ (string-length src) 1)]
    [toks : (Array Token) (make-array Token cap)]
    [starts : (Array i64) (make-array i64 cap)]
    (match (lex-into-spanned-result src toks starts)
      [(OkLexIntoSpanned count)
        (let
          [stoks : (Array SpannedToken) (make-array SpannedToken (+ count 1))]
          (begin
            (fill-spanned src toks starts stoks (+ count 1))
            (OkSpannedTokens stoks)))]
      [(ErrLexIntoSpanned err) (ErrSpannedTokens err)])))

(define (lex-spanned [src : String]) : (Array SpannedToken)
  (match (lex-spanned-result src)
    [(OkSpannedTokens toks) toks]
    [(ErrSpannedTokens err)
      (begin
        (panic (source-error-message err))
        (make-array SpannedToken 1))]))

(define (lex-percent-symbol-ok?) : bool
  (match (lex-result "(% n 16)")
    [(OkTokens toks)
      (and
        (= (token-tag (array-ref toks 1)) (tag-sym))
        (string-eq (token-sym (array-ref toks 1)) "%"))]
    [(ErrTokens _) false]))

(define (lex-ampersand-symbol-ok?) : bool
  (match (lex-result "(& r String) (&mut r String)")
    [(OkTokens toks)
      (and
        (= (token-tag (array-ref toks 1)) (tag-sym))
        (and
          (string-eq (token-sym (array-ref toks 1)) "&")
          (and
            (= (token-tag (array-ref toks 6)) (tag-sym))
            (string-eq (token-sym (array-ref toks 6)) "&mut"))))]
    [(ErrTokens _) false]))

(define (lex-float-token-ok?) : bool
  (match (lex-result "(3.14)")
    [(OkTokens toks)
      (and
        (= (token-tag (array-ref toks 1)) (tag-float))
        (string-eq (token-float (array-ref toks 1)) "3.14"))]
    [(ErrTokens _) false]))

(define (lex-negative-int-token-ok?) : bool
  (match (lex-result "(-1 - x)")
    [(OkTokens toks)
      (and
        (= (token-tag (array-ref toks 1)) (tag-int))
        (and
          (= (token-int (array-ref toks 1)) -1)
          (and
            (= (token-tag (array-ref toks 2)) (tag-sym))
            (string-eq (token-sym (array-ref toks 2)) "-"))))]
    [(ErrTokens _) false]))

;; Returns 42 when the spanned lexer records correct 1-based line/column
;; positions, including a token inside a nested list and the trailing EOF.
;; Source `"(a\n  (b c))"` lexes to:
;;   0:'(' 1:1   1:'a' 1:2   2:'(' 2:3   3:'b' 2:4   4:'c' 2:6
;;   5:')' 2:7   6:')' 2:8   7:TEnd 2:9
(define (lex-quote-text) : String
  "\"")

(define (lex-backslash-text) : String
  "\\")

(define (lex-basic-token-sequence-ok?) : bool
  (match (lex-result "(define [x : i64] -42 \"ok\" #\\newline')")
    [(OkTokens toks)
      (let
        [ok : bool true]
        (begin
          (if (= (token-tag (array-ref toks 0)) (tag-lparen))
            unit
            (set! ok false))
          (if (= (token-tag (array-ref toks 1)) (tag-sym))
            unit
            (set! ok false))
          (if (string-eq (token-sym (array-ref toks 1)) "define")
            unit
            (set! ok false))
          (if (= (token-tag (array-ref toks 2)) (tag-lbracket))
            unit
            (set! ok false))
          (if (string-eq (token-sym (array-ref toks 3)) "x")
            unit
            (set! ok false))
          (if (string-eq (token-sym (array-ref toks 4)) ":")
            unit
            (set! ok false))
          (if (string-eq (token-sym (array-ref toks 5)) "i64")
            unit
            (set! ok false))
          (if (= (token-tag (array-ref toks 6)) (tag-rbracket))
            unit
            (set! ok false))
          (if (= (token-int (array-ref toks 7)) -42)
            unit
            (set! ok false))
          (if (string-eq (token-str (array-ref toks 8)) "ok")
            unit
            (set! ok false))
          (if (= (token-char (array-ref toks 9)) #\newline')
            unit
            (set! ok false))
          (if (= (token-tag (array-ref toks 10)) (tag-rparen))
            unit
            (set! ok false))
          (if (= (token-tag (array-ref toks 11)) (tag-end))
            unit
            (set! ok false))
          ok))]
    [(ErrTokens _) false]))

(define (lex-char-source [body : String]) : String
  (string-append "#" (string-append body "'")))

(define (lex-one-char-ok? [body : String] [want : char]) : bool
  (match (lex-result (lex-char-source body))
    [(OkTokens toks)
      (and
        (= (token-tag (array-ref toks 0)) (tag-char))
        (and
          (= (token-char (array-ref toks 0)) want)
          (= (token-tag (array-ref toks 1)) (tag-end))))]
    [(ErrTokens _) false]))

(define (lex-char-literals-ok?) : bool
  (let
    [slash : String (lex-backslash-text)]
    (and
      (lex-one-char-ok? "x" #x')
      (and
        (lex-one-char-ok? (string-append slash "n") #\newline')
        (and
          (lex-one-char-ok? (string-append slash "t") #\tab')
          (and
            (lex-one-char-ok? (string-append slash "0") #\nul')
            (and
              (lex-one-char-ok? (string-append slash "space") #\space')
              (and
                (lex-one-char-ok? (string-append slash "newline") #\newline')
                (and
                  (lex-one-char-ok? (string-append slash "tab") #\tab')
                  (and
                    (lex-one-char-ok? (string-append slash "return") #\return')
                    (lex-one-char-ok? (string-append slash "nul") #\nul')))))))))))

(define (lex-error-ok?
  [src : String]
  [want-line : i64]
  [want-col : i64]
  [want-message : String]) : bool
  (match (lex-spanned-result src)
    [(OkSpannedTokens _) false]
    [(ErrSpannedTokens err)
      (and
        (string-eq (source-error-message err) want-message)
        (span-eq? (source-error-span err) want-line want-col want-line want-col))]))

(define (lex-error-spans-ok?) : bool
  (and
    (lex-error-ok? "\n#\\bogus'" 2 1 "lexer: unknown named character literal")
    (lex-error-ok? "ok\n@" 2 1 "lexer: unexpected character")))

(define (lex-string-source [inner : String]) : String
  (string-append (lex-quote-text) (string-append inner (lex-quote-text))))

(define (lex-string-token-ok? [src : String] [expected : String]) : bool
  (let
    [toks : (Array Token) (lex src)]
    (and
      (= (token-tag (array-ref toks 0)) (tag-str))
      (and
        (string-eq (token-str (array-ref toks 0)) expected)
        (= (token-tag (array-ref toks 1)) (tag-end))))))

(define (lex-escaped-quote-source-inner) : String
  (string-append
    "say "
    (string-append
      (lex-backslash-text)
      (string-append
        (lex-quote-text)
        (string-append
          "hi"
          (string-append (lex-backslash-text) (lex-quote-text)))))))

(define (lex-backslash-quote-source-inner) : String
  (string-append
    (lex-backslash-text)
    (string-append
      (lex-backslash-text)
      (string-append (lex-backslash-text) (lex-quote-text)))))

(define (lex-string-escapes-ok?) : bool
  (let
    [slash : String (lex-backslash-text)]
    [quote : String (lex-quote-text)]
    (and
      (lex-string-token-ok? (lex-string-source "hello\\nworld") "hello\nworld")
      (and
        (lex-string-token-ok?
          (lex-string-source (lex-escaped-quote-source-inner))
          (string-append
            "say "
            (string-append quote (string-append "hi" quote))))
        (and
          (lex-string-token-ok?
            (lex-string-source (string-append slash slash))
            slash)
          (lex-string-token-ok?
            (lex-string-source (lex-backslash-quote-source-inner))
            (string-append slash quote)))))))

(define (lex-quote-prefix-tokens-ok?) : bool
  (match (lex-result "`(if ,x ,@xs)")
    [(OkTokens toks)
      (and
        (= (token-tag (array-ref toks 0)) (tag-backtick))
        (and
          (= (token-tag (array-ref toks 3)) (tag-comma))
          (and
            (= (token-tag (array-ref toks 5)) (tag-comma-at))
            (and
              (= (token-tag (array-ref toks 7)) (tag-rparen))
              (= (token-tag (array-ref toks 8)) (tag-end))))))]
    [(ErrTokens _) false]))

(define (lex-span-positions-ok? [s : (Array SpannedToken)]) : bool
  (let
    [ok : bool true]
    (begin
      (if (= (spanned-token-line (array-ref s 0)) 1)
        unit
        (set! ok false))
      (if (= (spanned-token-col (array-ref s 0)) 1)
        unit
        (set! ok false))
      (if (= (spanned-token-col (array-ref s 1)) 2)
        unit
        (set! ok false))
      (if (= (spanned-token-line (array-ref s 2)) 2)
        unit
        (set! ok false))
      (if (= (spanned-token-col (array-ref s 2)) 3)
        unit
        (set! ok false))
      (if (= (spanned-token-col (array-ref s 3)) 4)
        unit
        (set! ok false))
      (if (= (spanned-token-col (array-ref s 4)) 6)
        unit
        (set! ok false))
      (if (= (spanned-token-line (array-ref s 7)) 2)
        unit
        (set! ok false))
      (if (= (spanned-token-col (array-ref s 7)) 9)
        unit
        (set! ok false))
      (if (= (token-tag (spanned-token-tok (array-ref s 7))) (tag-end))
        unit
        (set! ok false))
      ok)))

(define (lex-span-self-test) : i64
  (match (lex-spanned-result "(a\n  (b c))")
    [(OkSpannedTokens s)
      (if (and
        (lex-span-positions-ok? s)
        (and
          (lex-string-escapes-ok?)
          (and
            (lex-basic-token-sequence-ok?)
            (and
              (lex-char-literals-ok?)
              (and
                (lex-error-spans-ok?)
                (and
                  (lex-percent-symbol-ok?)
                  (and
                    (lex-ampersand-symbol-ok?)
                    (and
                      (lex-float-token-ok?)
                      (and
                        (lex-negative-int-token-ok?)
                        (lex-quote-prefix-tokens-ok?))))))))))
        42
        1)]
    [(ErrSpannedTokens _) 2]))
