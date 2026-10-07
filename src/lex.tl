;; lex.tl - The TypeLisp-syntax (s-expression) lexer as a `main`-less,
;; importable module.
;;
;; `spanned-result` scans source text into `token.SpannedToken` records, each
;; with the line and column of its first character; the reader (`read.tl`)
;; consumes them. `result` and `lex` copy the same token stream without
;; positions for the token-level tests; no compiler path reads it. The token
;; model (`token.Token`, its accessors and tag constants) stays behind the
;; `token.` qualifier.
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)

(module lex)

(import compiler_intern as ci)
(import compiler_builtin_ids as cbi)
(import stdlib.arena)
(import stdlib.io)
(import token)
(import stdlib.text_buf)
(import stdlib.string)
(import stdlib.result)
(import (result.result i64 String) as result_lex_i64)

(defmacro (global-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(defenum ResultTokens
  (Ok (__tl_dyn-array token.Token))
  (Err String))

(defenum ResultSpannedTokens
  (Ok (__tl_dyn-array token.SpannedToken))
  (Err token.SourceError))

(defenum ResultLexIntoSpanned
  (Ok i64)
  (Err token.SourceError))

(defenum ResultLexChar
  (Ok char)
  (Err String))

(defenum ResultMaybeLexCharLiteral
  (No)
  (Ok char i64)
  (Err String))

;; Dynamic capability used by standalone lexing and explicit compile jobs.
(defenum LexerInternOwner
  (:lifetimes intern-state)
  (Active)
  (State (& intern-state ci.InternCompatState)))

(define (ok? [message : (& message str)]) : bool
  (string.eq message ""))

;; `c` is a decimal digit char.
(define (is-digit [c : char]) : bool
  (and (>= c '0') (<= c '9')))

(define (is-hex-digit [c : char]) : bool
  (or (is-digit c) (and (>= c 'a') (<= c 'f')) (and (>= c 'A') (<= c 'F'))))

(define (is-binary-digit [c : char]) : bool
  (or (= c '0') (= c '1')))

(define (hex-digit-value [c : char]) : i64
  (let
    [code : i64 (cast c : i64)]
    (cond
      [(and (>= code 48) (<= code 57)) (- code 48)]
      [(and (>= code 97) (<= code 102)) (+ 10 (- code 97))]
      [(and (>= code 65) (<= code 70)) (+ 10 (- code 65))]
      [else 0])))

;; `c` may appear in a symbol: a letter, a digit, or a symbol-punctuation char.
;; A symbol run is the maximal span of these starting at a non-digit symbol char.
;; `scan-symbol-end` open-codes this same classifier; keep the two in step.
(define (is-symbol-char [c : char]) : bool
  (let
    [code : i64 (bit-and (cast c : i64) 255)]
    [folded : i64 (bit-or code 32)]
    (cond
      [(and (>= folded 97) (<= folded 122)) true]
      [(and (>= code 48) (<= code 57)) true]
      [(and (>= code 42) (<= code 63)) (and (!= code 44) (!= code 59))]
      [else (or (= code 33) (and (>= code 37) (<= code 38)) (= code 95))])))

(define (lexer-intern-source-slice-id
  [owner : (LexerInternOwner intern-state)]
  [src : (& src str)]
  [start : i64]
  [len : i64]) : ci.InternId
  (match owner
    [(Active) (ci.intern-source-slice-id src start len)]
    [(State state)
      (ci.intern-compat-state-source-slice-id-ready-ref state src start len)]))

(cfg
  compile-profile
  (define (lexer-intern-profile-note-source-bytes
    [owner : (LexerInternOwner intern-state)]
    [len : i64]) : unit
    (match owner
      [(Active) (ci.intern-profile-note-active-source-bytes len)]
      [(State state)
        (ci.intern-profile-note-source-bytes
          (ci.intern-compat-state-profile-metrics-address-ref state)
          len)])))

;; The lexer is also used by standalone tools that do not initialize the
;; compiler builtin-ID catalog. Keep the direct builtin fast path when it is
;; available, but derive the lone-colon identity from source otherwise.
(define (colon-intern-id
  [owner : (LexerInternOwner intern-state)]
  [src : (& src str)]
  [start : i64]) : ci.InternId
  (match owner
    [(Active)
      (if (ci.intern-renderable-id? cbi.compiler-builtin-id-fix-colon)
        (ci.intern-id-from-renderable cbi.compiler-builtin-id-fix-colon)
        (ci.intern-source-slice-id src start 1))]
    [(State _) (lexer-intern-source-slice-id owner src start 1)]))

;; `c` is ASCII whitespace.
(define (is-space [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

;; Return the end index (exclusive) of the digit run that starts at `start` in
;; `src`. `n` is the source length. The bounds check is kept outside the
;; `string-ref` (boolean `and` is not a short-circuit guard in lowered code).
(define (scan-int-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while keep
      (if (< j n)
        (if (is-digit (__tl_string_ref src j))
          (+= j 1)
          (set! keep false))
        (set! keep false)))
    j))

(define (scan-based-int-end
  [src : (& src str)]
  [start : i64]
  [n : i64]
  [base : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while keep
      (if (< j n)
        (let
          [c : char (__tl_string_ref src j)]
          (if (if (= base 16)
            (is-hex-digit c)
            (is-binary-digit c))
            (+= j 1)
            (set! keep false)))
        (set! keep false)))
    j))

(define (float-tail? [src : (& src str)] [int-end : i64] [n : i64]) : bool
  (if (< (+ int-end 1) n)
    (if (= (__tl_string_ref src int-end) '.')
      (is-digit (__tl_string_ref src (+ int-end 1)))
      false)
    false))

(define (scan-number-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [digits-start : i64 (number-digits-start src start)]
    [int-end : i64 (scan-int-end src digits-start n)]
    [j : i64 int-end]
    ;; A decimal fraction is accepted only when the dot is followed by at
    ;; least one digit.  The exponent is scanned after the complete
    ;; mantissa, so both integer and fraction forms share the same path.
    (if (float-tail? src int-end n)
      (set! j (scan-int-end src (+ int-end 1) n))
      unit)
    (if (< j n)
      (if (or (= (__tl_string_ref src j) 'e') (= (__tl_string_ref src j) 'E'))
        (let
          [mark : i64 j]
          [exp-digits : i64 (+ j 1)]
          (if (< exp-digits n)
            (if (or
              (= (__tl_string_ref src exp-digits) '+')
              (= (__tl_string_ref src exp-digits) '-'))
              (+= exp-digits 1)
              unit)
            unit)
          ;; Leave an exponent marker with no digits unconsumed.  The
          ;; result-producing wrapper below diagnoses it at the token start.
          (if (< exp-digits n)
            (if (is-digit (__tl_string_ref src exp-digits))
              (set! j (scan-int-end src exp-digits n))
              (set! j mark))
            (set! j mark)))
        unit)
      unit)
    j))

(define (number-digits-start [src : (& src str)] [start : i64]) : i64
  (if (= (__tl_string_ref src start) '-')
    (+ start 1)
    start))

(define (number-prefixed? [src : (& src str)] [start : i64] [n : i64]) : bool
  (let
    [digits-start : i64 (number-digits-start src start)]
    (if (< (+ digits-start 1) n)
      (if (= (__tl_string_ref src digits-start) '0')
        (let
          [prefix : char (__tl_string_ref src (+ digits-start 1))]
          (or (= prefix 'x') (= prefix 'X') (= prefix 'b') (= prefix 'B')))
        false)
      false)))

(define (number-prefix-base [src : (& src str)] [start : i64]) : i64
  (let
    [prefix : char (__tl_string_ref src (+ (number-digits-start src start) 1))]
    (if (or (= prefix 'x') (= prefix 'X'))
      16
      2)))

(define (scan-prefixed-int-end-result
  [src : (& src str)]
  [start : i64]
  [n : i64]) : result_lex_i64.Result
  (let
    [digits-start : i64 (number-digits-start src start)]
    [base : i64 (number-prefix-base src start)]
    [value-start : i64 (+ digits-start 2)]
    [end : i64 (scan-based-int-end src value-start n base)]
    (if (= end value-start)
      (Err "lexer: malformed integer literal")
      (if (if (< end n)
        (is-symbol-char (__tl_string_ref src end))
        false)
        (Err "lexer: malformed integer literal")
        (Ok end)))))

(define (scan-number-end-result [src : (& src str)] [start : i64] [n : i64]) : result_lex_i64.Result
  (if (number-prefixed? src start n)
    (scan-prefixed-int-end-result src start n)
    (let
      [end : i64 (scan-number-end src start n)]
      ;; Decimal exponent markers are part of a number only when followed by
      ;; an optional sign and at least one digit.  Once a decimal token is
      ;; complete, a symbol byte cannot begin a second token: rejecting that
      ;; fusion keeps malformed literals recoverable and source-located.
      [malformed : bool
        (or
          (if (< end n)
            (or
              (= (__tl_string_ref src end) 'e')
              (= (__tl_string_ref src end) 'E'))
            false)
          (if (< end n)
            (is-symbol-char (__tl_string_ref src end))
            false))]
      (if malformed
        (Err
          (str_cat.str-cat
            (string.substring "lexer: malformed integer literal" 0 17)
            "number"
            (string.substring "lexer: malformed integer literal" 24 8)))
        (Ok end)))))

(define (parse-based-int
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [base : i64]) : i64
  (let
    [value : i64 0]
    (for [j (iterator.range start end)]
      (set! value (+ (* value base) (hex-digit-value (__tl_string_ref src j)))))
    value))

(define (parse-prefixed-int [src : (& src str)] [start : i64] [end : i64]) : i64
  (let
    [digits-start : i64 (number-digits-start src start)]
    [sign : i64
      (if (= (__tl_string_ref src start) '-')
        -1
        1)]
    [base : i64 (number-prefix-base src start)]
    [value : i64 (parse-based-int src (+ digits-start 2) end base)]
    (* sign value)))

(define (number-int-value
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [n : i64]) : i64
  (if (number-prefixed? src start n)
    (parse-prefixed-int src start end)
    (string.>int (string.substring src start (- end start)))))

(define (number-decimal-zero-digits?
  [src : (& src str)]
  [start : i64]
  [end : i64]) : bool
  (let
    [i : i64 start]
    [zero? : bool true]
    (while (and zero? (< i end))
      (if (= (__tl_string_ref src i) '0')
        unit
        (set! zero? false))
      (+= i 1))
    zero?))

(define (number-int-text-needed?
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [n : i64]) : bool
  (if (number-prefixed? src start n)
    true
    (let
      [digits-start : i64 (number-digits-start src start)]
      [digit-count : i64 (- end digits-start)]
      (if (> digit-count 18)
        true
        (if (= (__tl_string_ref src start) '-')
          (number-decimal-zero-digits? src digits-start end)
          false)))))

(define (number-int-source-text
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [n : i64]) : String
  (if (number-int-text-needed? src start end n)
    (string.substring src start (- end start))
    ""))

(define (number-float? [src : (& src str)] [start : i64] [end : i64] [n : i64]) : bool
  (if (number-prefixed? src start n)
    false
    (let
      [i : i64 (number-digits-start src start)]
      [found : bool false]
      (while (and (< i end) (not found))
        (let
          [c : char (__tl_string_ref src i)]
          (if (or (= c '.') (= c 'e') (= c 'E'))
            (set! found true)
            unit)
          (+= i 1)))
      found)))

(define (negative-number-start? [src : (& src str)] [start : i64] [n : i64]) : bool
  (if (= (__tl_string_ref src start) '-')
    (if (< (+ start 1) n)
      (is-digit (__tl_string_ref src (+ start 1)))
      false)
    false))

(define (symbol-slice-eq?
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [value : String]) : bool
  (let
    [len : i64 (- end start)]
    (if (= len (string.string-length value))
      (string.eq (string.substring src start len) value)
      false)))

;; Return the end index (exclusive) of the symbol run that starts at `start` in
;; `src`. Same bounds-check discipline as `scan-int-end`.
;;
;; This is the lexer's hottest per-byte loop. The byte comes from the
;; `__tl_string_ref` intrinsic, which lowers to the same bounds-checked String
;; index that `string.string-ref` wraps. Keep its common letter path free of a
;; dynamic shift: safe scalar shifts retain their language-level count guards,
;; while ASCII case-folding and range tests need no second safety check.
;;
;; `:` is itself a symbol char, so testing membership first and the `:` rule
;; second is equivalent to testing `:` first: a non-`:` byte is decided by
;; `is-symbol-char` either way, and a `:` byte reaches the `pkg` rule either way.
(define (scan-symbol-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while keep
      (if (< j n)
        (let
          [code : i64 (bit-and (cast (__tl_string_ref src j) : i64) 255)]
          [folded : i64 (bit-or code 32)]
          [member : bool
            (cond
              [(and (>= folded 97) (<= folded 122)) true]
              [(and (>= code 48) (<= code 57)) true]
              [(and (>= code 42) (<= code 63)) (and (!= code 44) (!= code 59))]
              [else
                (or (= code 33) (and (>= code 37) (<= code 38)) (= code 95))])]
          (if member
            (if (and
              (= code 58)
              (> j start)
              (not (symbol-slice-eq? src start j "pkg")))
              (set! keep false)
              (+= j 1))
            (set! keep false)))
        (set! keep false)))
    j))

;; A `:` starts a colon-prefixed metadata/keyword symbol only when it is the
;; first non-space token in a list, such as `(:symbol ...)` or `(:link ...)`.
;; In annotation positions (`x:i64`, `x :i64`, `) :unit`) it remains a
;; standalone `:` delimiter.
(define (colon-symbol-head? [src : (& src str)] [start : i64]) : bool
  (let
    [j : i64 (- start 1)]
    [keep : bool true]
    [result : bool true]
    (while keep
      (if (< j 0)
        (set! keep false)
        (let
          [c : char (__tl_string_ref src j)]
          (if (is-space c)
            (-= j 1)
            (begin
              (set! result (= c '('))
              (set! keep false))))))
    result))

(define (colon-token-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [end : i64 (scan-symbol-end src start n)]
    (if (or
      (colon-symbol-head? src start)
      (symbol-slice-eq? src start end ":as"))
      end
      (+ start 1))))

;; Return the index of the closing `"` of a string literal whose inner text
;; starts at `start` (i.e. just AFTER the opening quote). `n` is the source
;; length. Scans forward until an unescaped `"` is found and returns its index.
;; Running off the end returns a recoverable lexer error. A backslash escapes the
;; following byte, so `\"` stays inside the string and a trailing backslash is an
;; unterminated string escape. Same bounds-check discipline as the other
;; scanners.
(define (scan-str-end-result [src : (& src str)] [start : i64] [n : i64]) : result_lex_i64.Result
  (let
    [j : i64 start]
    [keep : bool true]
    [message : String ""]
    (while keep
      (if (< j n)
        (let
          [c : char (__tl_string_ref src j)]
          (if (= c '"')
            (set! keep false)
            (if (= c '\\')
              (if (< (+ j 1) n)
                (+= j 2)
                (begin
                  (set! message "lexer: unterminated string escape")
                  (set! keep false)))
              (+= j 1))))
        (begin
          (set! message "lexer: unterminated string literal")
          (set! keep false))))
    (if (ok? message)
      (Ok j)
      (Err message))))

(define (string-escape-piece [src : (& src str)] [idx : i64]) : String
  (let
    [c : char (__tl_string_ref src idx)]
    (cond
      [(= c 'n') "\n"]
      [(= c 't') "\t"]
      [(= c 'r') "\r"]
      [(= c '\\') "\\"]
      [(= c '"') "\""]
      [else (string.substring src idx 1)])))

(define (unescape-string-literal [src : (& src str)] [start : i64] [end : i64]) : String
  (let
    [i : i64 start]
    [buf : text_buf.TextBuf (text_buf.empty)]
    (while (< i end)
      (let
        [c : char (__tl_string_ref src i)]
        (if (= c '\\')
          (if (< (+ i 1) end)
            (begin
              (set! buf (text_buf.append buf (string-escape-piece src (+ i 1))))
              (+= i 2))
            (begin
              (set! buf (text_buf.append buf "\\"))
              (+= i 1)))
          (begin
            (set! buf (text_buf.append buf (string.substring src i 1)))
            (+= i 1)))))
    (text_buf.render buf)))

;; Return the index of the end-of-line that ends a `;` line comment whose body
;; starts at `start`. `n` is the source length. Scans forward until a newline
;; or the end of the source, returning that index (the newline is
;; left for the main loop's whitespace skip to consume). Same bounds-check
;; discipline as the other scanners.
(define (scan-comment-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (while keep
      (if (< j n)
        (if (= (__tl_string_ref src j) '\n')
          (set! keep false)
          (+= j 1))
        (set! keep false)))
    j))

;; Return an empty string when a character literal has a closing `'` at `idx`,
;; otherwise return the recoverable lexer diagnostic.
(define (char-close-error [src : (& src str)] [idx : i64] [n : i64]) : String
  (if (< idx n)
    (if (= (__tl_string_ref src idx) '\'')
      ""
      "lexer: expected ' after character")
    "lexer: unterminated character literal"))

(define (apostrophe-escaped-char-result [c : char]) : ResultLexChar
  (cond
    [(= c 'n') (Ok '\n')]
    [(= c 't') (Ok '\t')]
    [(= c 'r') (Ok '\r')]
    [(= c '0') (Ok '\0')]
    [(= c '\\') (Ok '\\')]
    [(= c '\'') (Ok '\'')]
    [else (Err "lexer: unknown character escape")]))

(define (apostrophe-char-literal-result [src : (& src str)] [i : i64] [n : i64]) : ResultMaybeLexCharLiteral
  (if (< (+ i 1) n)
    (let
      [payload : char (__tl_string_ref src (+ i 1))]
      (cond
        [(= payload '\\')
          (let
            [esc-idx : i64 (+ i 2)]
            (if (< esc-idx n)
              (match (apostrophe-escaped-char-result
                (__tl_string_ref src esc-idx))
                [(Ok c)
                  (let
                    [message : String (char-close-error src (+ i 3) n)]
                    (if (ok? message)
                      (Ok c (+ i 4))
                      (Err message)))]
                [(Err message) (Err message)])
              (Err "lexer: unterminated character literal")))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r')) (No)]
        [else
          (if (< (+ i 2) n)
            (if (= (__tl_string_ref src (+ i 2)) '\'')
              (Ok payload (+ i 3))
              (No))
            (No))]))
    (No)))

(defenum LexPosition
  (Position i64 i64))

(define (advance-position
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [line : i64]
  [col : i64]) : LexPosition
  (let
    [next-line : i64 line]
    [next-col : i64 col]
    (for [j (iterator.range start end)]
      (if (= (__tl_string_ref src j) '\n')
        (begin
          (+= next-line 1)
          (set! next-col 1))
        (+= next-col 1)))
    (Position next-line next-col)))

;; Scan `src` into the shared spanned-token buffer, growing it on demand.
;; `limit` mirrors the global buffer capacity and is refreshed whenever it moves;
;; the guard at the top of the loop reserves room for this iteration's token AND
;; the trailing `token.Token.End`, so every `array-set!` below is in range
;; without a per-write capacity test.
(define (into-spanned-tokens-result-with-intern-owner
  [src : (& src str)]
  [owner : (LexerInternOwner intern-state)]) : ResultLexIntoSpanned
  (let
    [i : i64 0]
    [n : i64 (string.string-length src)]
    [count : i64 0]
    [line : i64 1]
    [col : i64 1]
    [ok : bool true]
    [message : String ""]
    [err-pos : i64 0]
    [limit : i64 (array-length lex-spanned-token-buffer)]
    (begin
      (cfg compile-profile (lexer-intern-profile-note-source-bytes owner n))
      (while (and (< i n) ok)
        (when
          (> (+ count 2) limit)
          (spanned-token-buffer-ensure! (+ count 2) count)
          (set! limit (array-length lex-spanned-token-buffer)))
        (let
          [c : char (__tl_string_ref src i)]
          (cond
            [(is-space c)
              (if (= c '\n')
                (begin
                  (+= line 1)
                  (set! col 1))
                (+= col 1))
              (+= i 1)]
            [(= c '(')
              (set!
                (array-ref lex-spanned-token-buffer count)
                (token.spanned-token-new LParen line col))
              (+= count 1)
              (+= i 1)
              (+= col 1)]
            [(= c '[')
              (set!
                (array-ref lex-spanned-token-buffer count)
                (token.spanned-token-new LBracket line col))
              (+= count 1)
              (+= i 1)
              (+= col 1)]
            [(= c ')')
              (set!
                (array-ref lex-spanned-token-buffer count)
                (token.spanned-token-new RParen line col))
              (+= count 1)
              (+= i 1)
              (+= col 1)]
            [(= c ']')
              (set!
                (array-ref lex-spanned-token-buffer count)
                (token.spanned-token-new RBracket line col))
              (+= count 1)
              (+= i 1)
              (+= col 1)]
            [(= c '\'')
              (let
                [token-line : i64 line]
                [token-col : i64 col]
                (match (apostrophe-char-literal-result src i n)
                  [(Ok value end)
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new
                        (Char value)
                        token-line
                        token-col))
                    (+= count 1)
                    (+= col (- end i))
                    (set! i end)]
                  [(Err err)
                    (set! ok false)
                    (set! message err)
                    (set! err-pos i)]
                  [(No)
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new Quote line col))
                    (+= count 1)
                    (+= i 1)
                    (+= col 1)]))]
            [(= c '`')
              (set!
                (array-ref lex-spanned-token-buffer count)
                (token.spanned-token-new Backtick line col))
              (+= count 1)
              (+= i 1)
              (+= col 1)]
            [(= c ',')
              (if (< (+ i 1) n)
                (if (= (__tl_string_ref src (+ i 1)) '@')
                  (begin
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new CommaAt line col))
                    (+= i 2)
                    (+= col 2))
                  (begin
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new Comma line col))
                    (+= i 1)
                    (+= col 1)))
                (begin
                  (set!
                    (array-ref lex-spanned-token-buffer count)
                    (token.spanned-token-new Comma line col))
                  (+= i 1)
                  (+= col 1)))
              (+= count 1)]
            [(= c '"')
              (let
                [start : i64 (+ i 1)]
                [token-line : i64 line]
                [token-col : i64 col]
                (match (scan-str-end-result src start n)
                  [(Ok end)
                    (let
                      [text : String (unescape-string-literal src start end)]
                      [string-id : ci.InternId
                        (lexer-intern-source-slice-id
                          owner
                          text
                          0
                          (string.string-length text))]
                      (set!
                        (array-ref lex-spanned-token-buffer count)
                        (token.spanned-token-new
                          (Str (token.token-intern-payload string-id))
                          token-line
                          token-col))
                      (+= count 1)
                      (match (advance-position src i (+ end 1) line col)
                        [(Position next-line next-col)
                          (set! line next-line)
                          (set! col next-col)])
                      (set! i (+ end 1)))]
                  [(Err err)
                    (set! ok false)
                    (set! message err)
                    (set! err-pos i)]))]
            [(= c ';')
              (let
                [end : i64 (scan-comment-end src (+ i 1) n)]
                (+= col (- end i))
                (set! i end))]
            [(or (is-digit c) (negative-number-start? src i n))
              (match (scan-number-end-result src i n)
                [(Ok end)
                  (let
                    [token-line : i64 line]
                    [token-col : i64 col]
                    (if (number-float? src i end n)
                      (set!
                        (array-ref lex-spanned-token-buffer count)
                        (token.spanned-token-new
                          (Float (string.substring src i (- end i)))
                          token-line
                          token-col))
                      (set!
                        (array-ref lex-spanned-token-buffer count)
                        (token.spanned-token-new
                          (Int
                            (number-int-value src i end n)
                            (number-int-source-text src i end n))
                          token-line
                          token-col)))
                    (+= count 1)
                    (+= col (- end i))
                    (set! i end))]
                [(Err err)
                  (set! ok false)
                  (set! message err)
                  (set! err-pos i)])]
            [(= c ':')
              (let
                [end : i64 (colon-token-end src i n)]
                (if (> end (+ i 1))
                  (begin
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new
                        (Sym
                          (token.token-intern-payload
                            (lexer-intern-source-slice-id owner src i (- end i))))
                        line
                        col))
                    (+= count 1)
                    (+= col (- end i))
                    (set! i end))
                  (begin
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new
                        (Sym
                          (token.token-intern-payload
                            (colon-intern-id owner src i)))
                        line
                        col))
                    (+= count 1)
                    (+= col 1)
                    (+= i 1))))]
            [(is-symbol-char c)
              (let
                [end : i64 (scan-symbol-end src i n)]
                (set!
                  (array-ref lex-spanned-token-buffer count)
                  (token.spanned-token-new
                    (Sym
                      (token.token-intern-payload
                        (lexer-intern-source-slice-id owner src i (- end i))))
                    line
                    col))
                (+= count 1)
                (+= col (- end i))
                (set! i end))]
            [else
              (set! ok false)
              (set! message "lexer: unexpected character")
              (set! err-pos i)])))
      (if ok
        (begin
          (when
            (>= count limit)
            (spanned-token-buffer-ensure! (+ count 1) count)
            unit)
          (set!
            (array-ref lex-spanned-token-buffer count)
            (token.spanned-token-new End line col))
          (Ok count))
        (Err (source-error-at src err-pos message))))))

;; ---- Spanned token stream ----------------------------------------------------
;; Each token is paired with the 1-based line/column of its starting byte; the
;; trailing `token.Token.End` carries the position one past the last character.
;; 1-based line of byte index `idx` in `src`: 1 + the number of newlines before
;; `idx`.
(define (index-line [src : (& src str)] [idx : i64]) : i64
  (let
    [line : i64 1]
    (for [k (iterator.range 0 idx)]
      (if (= (__tl_string_ref src k) '\n')
        (+= line 1)
        unit))
    line))

;; 1-based column of byte index `idx`: characters since the last newline (the
;; first column is 1).
(define (index-col [src : (& src str)] [idx : i64]) : i64
  (let
    [col : i64 1]
    (for [k (iterator.range 0 idx)]
      (if (= (__tl_string_ref src k) '\n')
        (set! col 1)
        (+= col 1)))
    col))

(define (source-error-at [src : (& src str)] [idx : i64] [message : String]) : token.SourceError
  (let
    [line : i64 (index-line src idx)]
    [col : i64 (index-col src idx)]
    (token.source-error-new message (token.source-span-new line col line col))))

;; Reusable spanned-token buffer, sized by TOKEN COUNT.
;;
;; Reserving from the SOURCE BYTE COUNT (`srclen + 1`, a safe upper bound since
;; a token spans >= 1 byte) oversizes it many times over, because a typical
;; token spans several bytes, and `make-array` zero-writes every slot it
;; reserves, all of it into slots that no consumer ever reads.
;;
;; So: no source-derived reservation and no cap. The lexer grows this buffer
;; on demand while it scans (geometric, contents preserved), which makes the
;; steady-state size the largest TOKEN count seen, not the largest file. Every
;; caller consumes the token array immediately (lex -> read -> parse,
;; sequentially per module) and never lexes again while one is live, so a
;; single program-lifetime buffer backs them all. The backing allocations live
;; in a dedicated arena replaced on growth, so a
;; grow while a transient driver arena is active cannot leave this global
;; pointing at reclaimed storage. A caller that can prove no parse is in flight
;; may retire that arena outright with `spanned-token-buffer-release!`; the next
;; scan simply grows a fresh one from zero.
(define lex-spanned-token-buffer : (__tl_dyn-array token.SpannedToken)
  (__tl_make-array token.SpannedToken 0))
(define lex-spanned-token-buffer-arena : i64
  0)

;; Permanent zero-length buffer installed by `spanned-token-buffer-release!`.
;; It is materialized once during global initialization, in the process entry
;; arena, exactly like the initial buffer above - so the global still names
;; live storage after the dedicated growth arena has been unmapped, and the
;; next `spanned-token-buffer-ensure!` grows from zero into a fresh arena.
(define lex-spanned-token-buffer-released : (__tl_dyn-array token.SpannedToken)
  (__tl_make-array token.SpannedToken 0))

(define (spanned-token-buffer-arena-handle-value) : i64
  lex-spanned-token-buffer-arena)

(define (spanned-token-buffer-next-capacity [required : i64]) : i64
  (let
    [current : i64 (array-length lex-spanned-token-buffer)]
    [next : i64
      (if (< current 1024)
        1024
        current)]
    (while (< next required)
      (set! next (* next 2)))
    next))

;; Install a larger buffer holding at least `required` slots, preserving the
;; first `used` records. `in-arena` restores the caller before the copy so the
;; copy cannot extend the storage arena. Only the current buffer survives:
;; superseded geometric capacities are retired after the live prefix is moved.
;; No consumer receives this array until scanning ends, and token payloads are
;; owned outside this arena (see the release contract below).
(define (spanned-token-buffer-grow-to! [required : i64] [used : i64]) : unit
  (let
    [old-storage-arena : i64 lex-spanned-token-buffer-arena]
    [caller-arena : i64 (arena.tl_arena_current)]
    [storage-root : i64 (arena.tl_arena_make)]
    [new-buffer : (__tl_dyn-array token.SpannedToken)
      (in-arena
        (arena.Arena storage-root)
        (__tl_make-array
          token.SpannedToken
          (spanned-token-buffer-next-capacity required)))]
    ;; Fresh disjoint storage; initialized inline records move as bytes.
    ;; `used` is the completed scanner prefix, excluding the next token.
    (unsafe
      (string.string-runtime-copy-bytes!
        (ptr-cast (__tl_array-data new-buffer) : (MutPtr u8))
        (ptr-cast (__tl_array-data lex-spanned-token-buffer) : (Ptr u8))
        (cast
          (-
            (ptr->int (ptr-offset (__tl_array-data new-buffer) used))
            (ptr->int (__tl_array-data new-buffer)))
          : i64)))
    (set! lex-spanned-token-buffer-arena storage-root)
    (set! lex-spanned-token-buffer new-buffer)
    (unless
      (= old-storage-arena 0)
      (unsafe
        (arena.tl_arena_destroy old-storage-arena)
        (arena.tl_arena_set caller-arena)))))

(define (spanned-token-buffer-ensure! [required : i64] [used : i64]) : unit
  (if (> required (array-length lex-spanned-token-buffer))
    (spanned-token-buffer-grow-to! required used)
    unit))

;; Store one record. Only this module may write the buffer, so the ownership
;; test parks its witness through this.
(define (spanned-token-buffer-set! [index : i64] [record : token.SpannedToken]) : unit
  (set! (array-ref lex-spanned-token-buffer index) record))

;; Unmap the dedicated growth arena and reinstall the zero-length buffer.
;;
;; No-dangling argument (the buffer array is aliased, so this needs one):
;;
;;   - `spanned-result` is the ONLY entry point that hands out this global; the
;;     plain `result`/`lex` entries copy the tokens into a fresh `token.Token`
;;     array per call (see `result-with-intern-owner` below).
;;   - No `(__tl_dyn-array token.SpannedToken)` is ever a struct field anywhere
;;     in the tree: every occurrence outside this module is a parameter or a
;;     `let` local of the reader/parser (`read.tl` `form-spanned-result` and
;;     friends, `compiler_parse_core.tl` `parse-ast-program*`). No state,
;;     session cache, or driver struct retains one. `CompilerParseState` holds
;;     only i64/env/intern cells.
;;   - Consumption is synchronous: `spanned-result` -> `parse-ast-program*` ->
;;     `reader.form-spanned-result`, which copies tags, interned ids, literal
;;     `String` handles, and `token.SourceSpan` line/col VALUES out of each
;;     record into pooled `SpannedSexpr` nodes. Nothing keeps a token index.
;;   - Diagnostics render eagerly: lexer errors build message plus span at the
;;     failure point (`source-error-at`), parser error spans are stored as four
;;     i64 line/col fields, and the reader formats mismatched-delimiter text
;;     with the span already in hand. There is no deferred slice of token text.
;;   - The `token.Token.Int`/`Token.Float` payload `String`s and every interned
;;     lexeme live elsewhere: interning copies bytes into the intern-persistent
;;     arena, and literal spellings are `string.substring` copies in whatever
;;     arena was current while lexing. This arena is made current only around
;;     the `make-array` inside `spanned-token-buffer-grow-to!`, so it backs the
;;     record array and nothing else.
;;
;; Callers must therefore only prove that no parse is in flight. Re-lexing
;; after a release is fine: the buffer regrows geometrically from zero.
(define (spanned-token-buffer-release!) : unit
  (if (= lex-spanned-token-buffer-arena 0)
    unit
    (let
      [retire-arena : i64 lex-spanned-token-buffer-arena]
      [retained-arena : i64 (arena.tl_arena_current)]
      ;; The sentinel remains owned by its permanent global. Reinstall only
      ;; a shared representation view; a direct RHS would move a non-Copy
      ;; dynamic array out of that global.
      (set!
        lex-spanned-token-buffer
        (unsafe
          (ptr-read (ptr-addr-of lex-spanned-token-buffer-released))))
      (set! lex-spanned-token-buffer-arena 0)
      (unsafe
        (arena.tl_arena_destroy retire-arena)
        (arena.tl_arena_set retained-arena)))))

;; `spanned-result : (-> String ResultSpannedTokens)` - lex into the shared
;; spanned-token buffer and hand back that buffer; slot `count` holds the
;; trailing `token.Token.End`. The buffer identity can change during the scan
;; (growth), so it is re-read from the global here rather than captured before.
(define (spanned-result-with-intern-owner
  [src : String]
  [owner : (LexerInternOwner intern-state)]) : ResultSpannedTokens
  (let
    [_ (try (into-spanned-tokens-result-with-intern-owner (& src) owner))]
    (Ok (global-shared-view lex-spanned-token-buffer))))

;; Serial/tool compatibility adapter. Compile jobs use the explicit twin below.
(define (spanned-result [src : String]) : ResultSpannedTokens
  (spanned-result-with-intern-owner src Active))

(define (spanned-result-with-intern-state
  [src : String]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : ResultSpannedTokens
  (ci.intern-compat-state-ensure-ready! intern-state)
  (spanned-result-with-intern-owner src (State (& intern-state))))

;; The spanned token stream without positions, copied into a fresh array that
;; ends in `token.Token.End`, for callers that compare token streams.
(define (result-with-intern-owner
  [src : String]
  [owner : (LexerInternOwner intern-state)]) : ResultTokens
  (match (spanned-result-with-intern-owner src owner)
    [(Err err) (Err (token.source-error-message err))]
    [(Ok spanned)
      (let
        [toks : (__tl_dyn-array token.Token)
          (__tl_make-array token.Token (array-length spanned))]
        [index : i64 0]
        [more : bool true]
        (while more
          (let
            [tok : token.Token
              (token.spanned-token-tok (array-shared-view spanned index))]
            (set! more (!= (token.tag-ref (& tok)) (token.tag-end)))
            (set! (array-ref toks index) tok)
            (+= index 1)))
        (Ok toks))]))

(define (result [src : String]) : ResultTokens
  (result-with-intern-owner src Active))

(define (lex [src : String]) : (__tl_dyn-array token.Token)
  (match (result src)
    [(Ok toks) toks]
    [(Err message) (io.panic message)]))