;; lex.tl - The TypeLisp-syntax (s-expression) lexer factored out as a
;; `main`-less, importable module.
;;
;; --------------------------------------------------------------------------
;; Why this module exists (the module signal for the reader).
;; --------------------------------------------------------------------------
;; `lexer.tl` is the *demo* program for the s-expression lexer: it carries a
;; `main` that lexes a sample and tallies its symbols. But the next front-end
;; component - the s-expression *reader* in `reader.tl` - wants to REUSE the
;; lexer's `lex : (-> String (__tl_dyn-array token.Token))` rather than
;; re-derive it, and it carries its own `main` (read tokens into a recursive
;; `Sexpr` tree, fold it).
;;
;; The module loader is whole-program: it concatenates every imported
;; module's declarations into a single program, then runs the unchanged
;; `typecheck -> lower -> codegen` pipeline. So two modules that both declare a
;; `main` and are loaded together produce a duplicate `main` symbol - the known
;; module limitation. Importing `lexer.tl` (which HAS a `main`) into the
;; reader (which also needs a `main`) would clash.
;;
;; The fix is this `main`-less module: it holds the lexer's scanners, the
;; recoverable `result` entry, the legacy `lex` wrapper, `(import)`s the
;; shared `main`-less `token` module, and declares NO `main`. The reader
;; imports this module for `lex` and imports `token` directly for token types,
;; so the concatenated program has exactly one
;; `main` (the reader's). `lexer.tl`
;; stays as the lexer's standalone demo. This mirrors how `calc.tl` imports the
;; `main`-less `token.tl`: a `main`-less module is the unit of reuse, a
;; `main`-bearing file is a runnable demo.
;; The shared token model: the `token.Token` enum and the `token.tag` / `token.int` /
;; `token.sym` / `token.str` / `token.char` / `token.float` accessors and tag
;; constants.
;; Imported by module name so token declarations stay behind the `token.`
;; qualifier instead of flattening through `lex.tl`.
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
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(defmacro (array-shared-view [items : Expr] [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (array-data ,items) ,index))))

(defenum ResultTokens
  (Ok (__tl_dyn-array token.Token))
  (Err String))

(defenum ResultSpannedTokens
  (Ok (__tl_dyn-array token.SpannedToken))
  (Err token.SourceError))

(defenum ResultLexCheck
  (Ok i64)
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

;; Numeric code point of a char, used only when a code value is intentionally
;; observed (for example in the lexer demo's character-code checksum).
(define (code [c : char]) : i64
  (cast c : i64))

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
    (begin
      (while keep
        (if (< j n)
          (if (is-digit (__tl_string_ref src j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

(define (scan-based-int-end
  [src : (& src str)]
  [start : i64]
  [n : i64]
  [base : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (__tl_string_ref src j)]
            (if (if (= base 16)
              (is-hex-digit c)
              (is-binary-digit c))
              (set! j (+ j 1))
              (set! keep false)))
          (set! keep false)))
      j)))

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
    (begin
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
            (begin
              (if (< exp-digits n)
                (if (or
                  (= (__tl_string_ref src exp-digits) '+')
                  (= (__tl_string_ref src exp-digits) '-'))
                  (set! exp-digits (+ exp-digits 1))
                  unit)
                unit)
              ;; Leave an exponent marker with no digits unconsumed.  The
              ;; result-producing wrapper below diagnoses it at the token start.
              (if (< exp-digits n)
                (if (is-digit (__tl_string_ref src exp-digits))
                  (set! j (scan-int-end src exp-digits n))
                  (set! j mark))
                (set! j mark))))
          unit)
        unit)
      j)))

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
      (result_lex_i64.Err "lexer: malformed integer literal")
      (if (if (< end n)
        (is-symbol-char (__tl_string_ref src end))
        false)
        (result_lex_i64.Err "lexer: malformed integer literal")
        (result_lex_i64.Ok end)))))

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
        (result_lex_i64.Err
          (str_cat.str-cat
            (string.substring "lexer: malformed integer literal" 0 17)
            "number"
            (string.substring "lexer: malformed integer literal" 24 8)))
        (result_lex_i64.Ok end)))))

(define (parse-based-int
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [base : i64]) : i64
  (let
    [j : i64 start]
    [value : i64 0]
    (begin
      (while (< j end)
        (begin
          (set!
            value
            (+ (* value base) (hex-digit-value (__tl_string_ref src j))))
          (set! j (+ j 1))))
      value)))

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
    (begin
      (while (and zero? (< i end))
        (begin
          (if (= (__tl_string_ref src i) '0')
            unit
            (set! zero? false))
          (set! i (+ i 1))))
      zero?)))

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
      (begin
        (while (and (< i end) (not found))
          (let
            [c : char (__tl_string_ref src i)]
            (if (or (= c '.') (= c 'e') (= c 'E'))
              (set! found true)
              unit)
            (set! i (+ i 1))))
        found))))

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
;; second is equivalent to the original order: a non-`:` byte was decided by
;; `is-symbol-char` either way, and a `:` byte reaches the `pkg` rule either way.
(define (scan-symbol-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [code : i64 (bit-and (cast (__tl_string_ref src j) : i64) 255)]
            [folded : i64 (bit-or code 32)]
            [member : bool
              (cond
                [(and (>= folded 97) (<= folded 122)) true]
                [(and (>= code 48) (<= code 57)) true]
                [(and (>= code 42) (<= code 63))
                  (and (!= code 44) (!= code 59))]
                [else
                  (or (= code 33) (and (>= code 37) (<= code 38)) (= code 95))])]
            (if member
              (if (and
                (= code 58)
                (> j start)
                (not (symbol-slice-eq? src start j "pkg")))
                (set! keep false)
                (set! j (+ j 1)))
              (set! keep false)))
          (set! keep false)))
      j)))

;; A `:` starts a colon-prefixed metadata/keyword symbol only when it is the
;; first non-space token in a list, such as `(:symbol ...)` or `(:link ...)`.
;; In annotation positions (`x:i64`, `x :i64`, `) :unit`) it remains a
;; standalone `:` delimiter.
(define (colon-symbol-head? [src : (& src str)] [start : i64]) : bool
  (let
    [j : i64 (- start 1)]
    [keep : bool true]
    [result : bool true]
    (begin
      (while keep
        (if (< j 0)
          (set! keep false)
          (let
            [c : char (__tl_string_ref src j)]
            (if (is-space c)
              (set! j (- j 1))
              (begin
                (set! result (= c '('))
                (set! keep false))))))
      result)))

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
    (begin
      (while keep
        (if (< j n)
          (let
            [c : char (__tl_string_ref src j)]
            (if (= c '"')
              (set! keep false)
              (if (= c '\\')
                (if (< (+ j 1) n)
                  (set! j (+ j 2))
                  (begin
                    (set! message "lexer: unterminated string escape")
                    (set! keep false)))
                (set! j (+ j 1)))))
          (begin
            (set! message "lexer: unterminated string literal")
            (set! keep false))))
      (if (ok? message)
        (result_lex_i64.Ok j)
        (result_lex_i64.Err message)))))

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
    (begin
      (while (< i end)
        (let
          [c : char (__tl_string_ref src i)]
          (if (= c '\\')
            (if (< (+ i 1) end)
              (begin
                (set!
                  buf
                  (text_buf.append buf (string-escape-piece src (+ i 1))))
                (set! i (+ i 2)))
              (begin
                (set! buf (text_buf.append buf "\\"))
                (set! i (+ i 1))))
            (begin
              (set! buf (text_buf.append buf (string.substring src i 1)))
              (set! i (+ i 1))))))
      (text_buf.render buf))))

;; Return the index of the end-of-line that ends a `;` line comment whose body
;; starts at `start`. `n` is the source length. Scans forward until a newline
;; or the end of the source, returning that index (the newline is
;; left for the main loop's whitespace skip to consume). Same bounds-check
;; discipline as the other scanners.
(define (scan-comment-end [src : (& src str)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (= (__tl_string_ref src j) '\n')
            (set! keep false)
            (set! j (+ j 1)))
          (set! keep false)))
      j)))

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
    [(= c 'n') (ResultLexChar.Ok '\n')]
    [(= c 't') (ResultLexChar.Ok '\t')]
    [(= c 'r') (ResultLexChar.Ok '\r')]
    [(= c '0') (ResultLexChar.Ok '\0')]
    [(= c '\\') (ResultLexChar.Ok '\\')]
    [(= c '\'') (ResultLexChar.Ok '\'')]
    [else (ResultLexChar.Err "lexer: unknown character escape")]))

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
                [(ResultLexChar.Ok c)
                  (let
                    [message : String (char-close-error src (+ i 3) n)]
                    (if (ok? message)
                      (ResultMaybeLexCharLiteral.Ok c (+ i 4))
                      (ResultMaybeLexCharLiteral.Err message)))]
                [(ResultLexChar.Err message)
                  (ResultMaybeLexCharLiteral.Err message)])
              (ResultMaybeLexCharLiteral.Err
                "lexer: unterminated character literal")))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r'))
          (ResultMaybeLexCharLiteral.No)]
        [else
          (if (< (+ i 2) n)
            (if (= (__tl_string_ref src (+ i 2)) '\'')
              (ResultMaybeLexCharLiteral.Ok payload (+ i 3))
              (ResultMaybeLexCharLiteral.No))
            (ResultMaybeLexCharLiteral.No))]))
    (ResultMaybeLexCharLiteral.No)))

(define (check-step [src : (& src str)] [i : i64] [n : i64]) : result_lex_i64.Result
  (let
    [c : char (__tl_string_ref src i)]
    (cond
      [(is-space c) (result_lex_i64.Ok (+ i 1))]
      [(or (= c '(') (= c '[')) (result_lex_i64.Ok (+ i 1))]
      [(or (= c ')') (= c ']')) (result_lex_i64.Ok (+ i 1))]
      [(= c '\'')
        (match (apostrophe-char-literal-result src i n)
          [(ResultMaybeLexCharLiteral.Ok _ end) (result_lex_i64.Ok end)]
          [(ResultMaybeLexCharLiteral.Err message) (result_lex_i64.Err message)]
          [(ResultMaybeLexCharLiteral.No) (result_lex_i64.Ok (+ i 1))])]
      [(= c '`') (result_lex_i64.Ok (+ i 1))]
      [(= c ',')
        (if (< (+ i 1) n)
          (if (= (__tl_string_ref src (+ i 1)) '@')
            (result_lex_i64.Ok (+ i 2))
            (result_lex_i64.Ok (+ i 1)))
          (result_lex_i64.Ok (+ i 1)))]
      [(= c '"')
        (let
          [start : i64 (+ i 1)]
          (match (scan-str-end-result src start n)
            [(result_lex_i64.Ok end) (result_lex_i64.Ok (+ end 1))]
            [(result_lex_i64.Err message) (result_lex_i64.Err message)]))]
      [(= c ';') (result_lex_i64.Ok (scan-comment-end src (+ i 1) n))]
      [(or (is-digit c) (negative-number-start? src i n))
        (scan-number-end-result src i n)]
      [(is-symbol-char c) (result_lex_i64.Ok (scan-symbol-end src i n))]
      [else (result_lex_i64.Err "lexer: unexpected character")])))

(define (check-spanned [src : (& src str)]) : ResultLexCheck
  (let
    [i : i64 0]
    [n : i64 (string.string-length src)]
    [message : String ""]
    [err-pos : i64 0]
    (begin
      (while (and (< i n) (ok? message))
        (match (check-step src i n)
          [(result_lex_i64.Ok next) (set! i next)]
          [(result_lex_i64.Err err)
            (begin
              (set! message err)
              (set! err-pos i)
              (set! i n))]))
      (if (ok? message)
        (ResultLexCheck.Ok i)
        (ResultLexCheck.Err (source-error-at src err-pos message))))))

(define (check [src : String]) : result_lex_i64.Result
  (match (check-spanned src)
    [(ResultLexCheck.Ok end) (result_lex_i64.Ok end)]
    [(ResultLexCheck.Err err)
      (result_lex_i64.Err (token.source-error-message err))]))

;; Core scanner. Fills `toks` with the token stream and, in parallel, records
;; each token's starting byte index into `starts[count]`. The plain token
;; path uses this through `result`; `spanned-result` uses a direct
;; scanner that records line/column positions while tokenizing. Returns the
;; token count (excluding the trailing `token.Token.End`).
(define (into-spanned-result
  [src : (& src str)]
  [toks : (&mut toks (__tl_dyn-array token.Token))]
  [starts : (&mut starts (__tl_dyn-array i64))]
  [owner : (LexerInternOwner intern-state)]) : ResultLexIntoSpanned
  (let
    [i : i64 0]
    [n : i64 (string.string-length src)]
    [count : i64 0]
    [ok : bool true]
    [message : String ""]
    [err-pos : i64 0]
    (begin
      (cfg compile-profile (ci.intern-profile-note-source-bytes n))
      (while (and (< i n) ok)
        (let
          [c : char (__tl_string_ref src i)]
          (cond
            [(is-space c) (set! i (+ i 1))]
            [(= c '(')
              (begin
                (set! (array-ref starts count) i)
                (set! (array-ref toks count) token.Token.LParen)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c '[')
              (begin
                (set! (array-ref starts count) i)
                (set! (array-ref toks count) token.Token.LBracket)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c ')')
              (begin
                (set! (array-ref starts count) i)
                (set! (array-ref toks count) token.Token.RParen)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c ']')
              (begin
                (set! (array-ref starts count) i)
                (set! (array-ref toks count) token.Token.RBracket)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c '\'')
              (match (apostrophe-char-literal-result src i n)
                [(ResultMaybeLexCharLiteral.Ok value end)
                  (begin
                    (set! (array-ref starts count) i)
                    (set! (array-ref toks count) (token.Token.Char value))
                    (set! count (+ count 1))
                    (set! i end))]
                [(ResultMaybeLexCharLiteral.Err err)
                  (begin
                    (set! ok false)
                    (set! message err)
                    (set! err-pos i))]
                [(ResultMaybeLexCharLiteral.No)
                  (begin
                    (set! (array-ref starts count) i)
                    (set! (array-ref toks count) token.Token.Quote)
                    (set! count (+ count 1))
                    (set! i (+ i 1)))])]
            [(= c '`')
              (begin
                (set! (array-ref starts count) i)
                (set! (array-ref toks count) token.Token.Backtick)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c ',')
              (begin
                (set! (array-ref starts count) i)
                (if (< (+ i 1) n)
                  (if (= (__tl_string_ref src (+ i 1)) '@')
                    (begin
                      (set! (array-ref toks count) token.Token.CommaAt)
                      (set! i (+ i 2)))
                    (begin
                      (set! (array-ref toks count) token.Token.Comma)
                      (set! i (+ i 1))))
                  (begin
                    (set! (array-ref toks count) token.Token.Comma)
                    (set! i (+ i 1))))
                (set! count (+ count 1)))]
            [(= c '"')
              (let
                [start : i64 (+ i 1)]
                (match (scan-str-end-result src start n)
                  [(result_lex_i64.Ok end)
                    (let
                      [text : String (unescape-string-literal src start end)]
                      [string-id : ci.InternId
                        (lexer-intern-source-slice-id
                          owner
                          text
                          0
                          (string.string-length text))]
                      (begin
                        (set! (array-ref starts count) i)
                        (set!
                          (array-ref toks count)
                          (token.Token.Str
                            (token.token-intern-payload string-id)))
                        (set! count (+ count 1))
                        (set! i (+ end 1))))]
                  [(result_lex_i64.Err err)
                    (begin
                      (set! ok false)
                      (set! message err)
                      (set! err-pos i))]))]
            [(= c ';') (set! i (scan-comment-end src (+ i 1) n))]
            [(or (is-digit c) (negative-number-start? src i n))
              (match (scan-number-end-result src i n)
                [(result_lex_i64.Ok end)
                  (begin
                    (set! (array-ref starts count) i)
                    (if (number-float? src i end n)
                      (set!
                        (array-ref toks count)
                        (token.Token.Float (string.substring src i (- end i))))
                      (set!
                        (array-ref toks count)
                        (token.Token.Int
                          (number-int-value src i end n)
                          (number-int-source-text src i end n))))
                    (set! count (+ count 1))
                    (set! i end))]
                [(result_lex_i64.Err err)
                  (begin
                    (set! ok false)
                    (set! message err)
                    (set! err-pos i))])]
            [(= c ':')
              (let
                [end : i64 (colon-token-end src i n)]
                (if (> end (+ i 1))
                  (begin
                    (set! (array-ref starts count) i)
                    (set!
                      (array-ref toks count)
                      (token.Token.Sym
                        (token.token-intern-payload
                          (lexer-intern-source-slice-id owner src i (- end i)))))
                    (set! count (+ count 1))
                    (set! i end))
                  (begin
                    (set! (array-ref starts count) i)
                    (set!
                      (array-ref toks count)
                      (token.Token.Sym
                        (token.token-intern-payload
                          (colon-intern-id owner src i))))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))))]
            [(is-symbol-char c)
              (let
                [end : i64 (scan-symbol-end src i n)]
                (begin
                  (set! (array-ref starts count) i)
                  (set!
                    (array-ref toks count)
                    (token.Token.Sym
                      (token.token-intern-payload
                        (lexer-intern-source-slice-id owner src i (- end i)))))
                  (set! count (+ count 1))
                  (set! i end)))]
            [else
              (begin
                (set! ok false)
                (set! message "lexer: unexpected character")
                (set! err-pos i))])))
      (if ok
        (begin
          (set! (array-ref starts count) n)
          (set! (array-ref toks count) token.Token.End)
          (ResultLexIntoSpanned.Ok count))
        (ResultLexIntoSpanned.Err (source-error-at src err-pos message))))))

(defenum LexPosition
  (Position i64 i64))

(define (advance-position
  [src : (& src str)]
  [start : i64]
  [end : i64]
  [line : i64]
  [col : i64]) : LexPosition
  (let
    [j : i64 start]
    [next-line : i64 line]
    [next-col : i64 col]
    (begin
      (while (< j end)
        (begin
          (if (= (__tl_string_ref src j) '\n')
            (begin
              (set! next-line (+ next-line 1))
              (set! next-col 1))
            (set! next-col (+ next-col 1)))
          (set! j (+ j 1))))
      (LexPosition.Position next-line next-col))))

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
      (cfg compile-profile (ci.intern-profile-note-source-bytes n))
      (while (and (< i n) ok)
        (begin
          (if (> (+ count 2) limit)
            (begin
              (spanned-token-buffer-ensure! (+ count 2) count)
              (set! limit (array-length lex-spanned-token-buffer)))
            unit)
          (let
            [c : char (__tl_string_ref src i)]
            (cond
              [(is-space c)
                (begin
                  (if (= c '\n')
                    (begin
                      (set! line (+ line 1))
                      (set! col 1))
                    (set! col (+ col 1)))
                  (set! i (+ i 1)))]
              [(= c '(')
                (begin
                  (set!
                    (array-ref lex-spanned-token-buffer count)
                    (token.spanned-token-new token.Token.LParen line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c '[')
                (begin
                  (set!
                    (array-ref lex-spanned-token-buffer count)
                    (token.spanned-token-new token.Token.LBracket line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c ')')
                (begin
                  (set!
                    (array-ref lex-spanned-token-buffer count)
                    (token.spanned-token-new token.Token.RParen line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c ']')
                (begin
                  (set!
                    (array-ref lex-spanned-token-buffer count)
                    (token.spanned-token-new token.Token.RBracket line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c '\'')
                (let
                  [token-line : i64 line]
                  [token-col : i64 col]
                  (match (apostrophe-char-literal-result src i n)
                    [(ResultMaybeLexCharLiteral.Ok value end)
                      (begin
                        (set!
                          (array-ref lex-spanned-token-buffer count)
                          (token.spanned-token-new
                            (token.Token.Char value)
                            token-line
                            token-col))
                        (set! count (+ count 1))
                        (set! col (+ col (- end i)))
                        (set! i end))]
                    [(ResultMaybeLexCharLiteral.Err err)
                      (begin
                        (set! ok false)
                        (set! message err)
                        (set! err-pos i))]
                    [(ResultMaybeLexCharLiteral.No)
                      (begin
                        (set!
                          (array-ref lex-spanned-token-buffer count)
                          (token.spanned-token-new token.Token.Quote line col))
                        (set! count (+ count 1))
                        (set! i (+ i 1))
                        (set! col (+ col 1)))]))]
              [(= c '`')
                (begin
                  (set!
                    (array-ref lex-spanned-token-buffer count)
                    (token.spanned-token-new token.Token.Backtick line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c ',')
                (begin
                  (if (< (+ i 1) n)
                    (if (= (__tl_string_ref src (+ i 1)) '@')
                      (begin
                        (set!
                          (array-ref lex-spanned-token-buffer count)
                          (token.spanned-token-new token.Token.CommaAt line col))
                        (set! i (+ i 2))
                        (set! col (+ col 2)))
                      (begin
                        (set!
                          (array-ref lex-spanned-token-buffer count)
                          (token.spanned-token-new token.Token.Comma line col))
                        (set! i (+ i 1))
                        (set! col (+ col 1))))
                    (begin
                      (set!
                        (array-ref lex-spanned-token-buffer count)
                        (token.spanned-token-new token.Token.Comma line col))
                      (set! i (+ i 1))
                      (set! col (+ col 1))))
                  (set! count (+ count 1)))]
              [(= c '"')
                (let
                  [start : i64 (+ i 1)]
                  [token-line : i64 line]
                  [token-col : i64 col]
                  (match (scan-str-end-result src start n)
                    [(result_lex_i64.Ok end)
                      (let
                        [text : String (unescape-string-literal src start end)]
                        [string-id : ci.InternId
                          (lexer-intern-source-slice-id
                            owner
                            text
                            0
                            (string.string-length text))]
                        (begin
                          (set!
                            (array-ref lex-spanned-token-buffer count)
                            (token.spanned-token-new
                              (token.Token.Str
                                (token.token-intern-payload string-id))
                              token-line
                              token-col))
                          (set! count (+ count 1))
                          (match (advance-position src i (+ end 1) line col)
                            [(LexPosition.Position next-line next-col)
                              (begin
                                (set! line next-line)
                                (set! col next-col))])
                          (set! i (+ end 1))))]
                    [(result_lex_i64.Err err)
                      (begin
                        (set! ok false)
                        (set! message err)
                        (set! err-pos i))]))]
              [(= c ';')
                (let
                  [end : i64 (scan-comment-end src (+ i 1) n)]
                  (begin
                    (set! col (+ col (- end i)))
                    (set! i end)))]
              [(or (is-digit c) (negative-number-start? src i n))
                (match (scan-number-end-result src i n)
                  [(result_lex_i64.Ok end)
                    (let
                      [token-line : i64 line]
                      [token-col : i64 col]
                      (begin
                        (if (number-float? src i end n)
                          (set!
                            (array-ref lex-spanned-token-buffer count)
                            (token.spanned-token-new
                              (token.Token.Float
                                (string.substring src i (- end i)))
                              token-line
                              token-col))
                          (set!
                            (array-ref lex-spanned-token-buffer count)
                            (token.spanned-token-new
                              (token.Token.Int
                                (number-int-value src i end n)
                                (number-int-source-text src i end n))
                              token-line
                              token-col)))
                        (set! count (+ count 1))
                        (set! col (+ col (- end i)))
                        (set! i end)))]
                  [(result_lex_i64.Err err)
                    (begin
                      (set! ok false)
                      (set! message err)
                      (set! err-pos i))])]
              [(= c ':')
                (let
                  [end : i64 (colon-token-end src i n)]
                  (if (> end (+ i 1))
                    (begin
                      (set!
                        (array-ref lex-spanned-token-buffer count)
                        (token.spanned-token-new
                          (token.Token.Sym
                            (token.token-intern-payload
                              (lexer-intern-source-slice-id
                                owner
                                src
                                i
                                (- end i))))
                          line
                          col))
                      (set! count (+ count 1))
                      (set! col (+ col (- end i)))
                      (set! i end))
                    (begin
                      (set!
                        (array-ref lex-spanned-token-buffer count)
                        (token.spanned-token-new
                          (token.Token.Sym
                            (token.token-intern-payload
                              (colon-intern-id owner src i)))
                          line
                          col))
                      (set! count (+ count 1))
                      (set! col (+ col 1))
                      (set! i (+ i 1)))))]
              [(is-symbol-char c)
                (let
                  [end : i64 (scan-symbol-end src i n)]
                  (begin
                    (set!
                      (array-ref lex-spanned-token-buffer count)
                      (token.spanned-token-new
                        (token.Token.Sym
                          (token.token-intern-payload
                            (lexer-intern-source-slice-id owner src i (- end i))))
                        line
                        col))
                    (set! count (+ count 1))
                    (set! col (+ col (- end i)))
                    (set! i end)))]
              [else
                (begin
                  (set! ok false)
                  (set! message "lexer: unexpected character")
                  (set! err-pos i))]))))
      (if ok
        (begin
          (if (>= count limit)
            (begin
              (spanned-token-buffer-ensure! (+ count 1) count)
              unit)
            unit)
          (set!
            (array-ref lex-spanned-token-buffer count)
            (token.spanned-token-new token.Token.End line col))
          (ResultLexIntoSpanned.Ok count))
        (ResultLexIntoSpanned.Err (source-error-at src err-pos message))))))

;; `lex : (-> String (__tl_dyn-array token.Token))` - the public entry point.
;; Size the token array by an upper bound (every char yields at most one token,
;; plus the `token.Token.End` sentinel), lex into it, then return that exact
;; array. The trailing `token.Token.End` marks
;; the logical end even though the backing array may be larger.
(define (result-with-intern-owner
  [src : String]
  [owner : (LexerInternOwner intern-state)]) : ResultTokens
  (let
    [cap : i64 (+ (string.string-length src) 1)]
    [toks : (__tl_dyn-array token.Token) (make-array token.Token cap)]
    [starts : (__tl_dyn-array i64) (make-array i64 cap)]
    (match (into-spanned-result (& src) (&mut toks) (&mut starts) owner)
      [(ResultLexIntoSpanned.Ok _) (ResultTokens.Ok toks)]
      [(ResultLexIntoSpanned.Err err)
        (ResultTokens.Err (token.source-error-message err))])))

;; Serial/tool compatibility adapter. Compile jobs use the explicit twin below.
(define (result [src : String]) : ResultTokens
  (result-with-intern-owner src LexerInternOwner.Active))

(define (result-with-intern-state
  [src : String]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : ResultTokens
  (begin
    (ci.intern-compat-state-ensure-ready! intern-state)
    (result-with-intern-owner src (LexerInternOwner.State (& intern-state)))))

(define (lex [src : String]) : (__tl_dyn-array token.Token)
  (match (result src)
    [(ResultTokens.Ok toks) toks]
    [(ResultTokens.Err message) (io.panic message)]))

;; ---- Spanned token stream ----------------------------------------------------
;; A position-bearing token stream parallel to `lex`/`result`. Each token is
;; paired with the 1-based line/column of its starting byte; the trailing
;; `token.Token.End`
;; carries the position one past the last character. The plain `token.Token` path
;; above is untouched, so existing callers keep working.
;; 1-based line of byte index `idx` in `src`: 1 + the number of newlines before
;; `idx`.
(define (index-line [src : (& src str)] [idx : i64]) : i64
  (let
    [line : i64 1]
    [k : i64 0]
    (begin
      (while (< k idx)
        (begin
          (if (= (__tl_string_ref src k) '\n')
            (set! line (+ line 1))
            unit)
          (set! k (+ k 1))))
      line)))

;; 1-based column of byte index `idx`: characters since the last newline (the
;; first column is 1).
(define (index-col [src : (& src str)] [idx : i64]) : i64
  (let
    [col : i64 1]
    [k : i64 0]
    (begin
      (while (< k idx)
        (begin
          (if (= (__tl_string_ref src k) '\n')
            (set! col 1)
            (set! col (+ col 1)))
          (set! k (+ k 1))))
      col)))

(define (source-error-at [src : (& src str)] [idx : i64] [message : String]) : token.SourceError
  (let
    [line : i64 (index-line src idx)]
    [col : i64 (index-col src idx)]
    (token.source-error-new message (token.source-span-new line col line col))))

;; Reusable spanned-token buffer, sized by TOKEN COUNT.
;;
;; This buffer used to be reserved from the SOURCE BYTE COUNT (`srclen + 1`, a
;; safe upper bound since a token spans >= 1 byte). Measured density in this
;; repository is one token per 8.84 source bytes, so that reservation was 8.8x
;; oversized - and `make-array` zero-writes every slot it reserves. Sources
;; above the old hard cap fell out of the reuse path entirely and allocated a
;; fresh `(srclen+1) x sizeof(SpannedToken)` array per file: 523 MB of zero-fill
;; per self-compile, 8.13M D1 write misses and 7.72M LL misses, all of it into
;; slots that no consumer ever reads (packet E1, target/e1-notes.md).
;;
;; So: no source-derived reservation and no cap. The lexer grows this buffer
;; on demand while it scans (geometric, contents preserved), which makes the
;; steady-state size the largest TOKEN count seen, not the largest file. Every
;; caller consumes the token array immediately (lex -> read -> parse,
;; sequentially per module) and never lexes again while one is live, so a
;; single program-lifetime buffer backs them all. The backing allocations live
;; in one dedicated arena that is created on first growth and never reset, so a
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
    (begin
      (while (< next required)
        (set! next (* next 2)))
      next)))

;; Install a larger buffer holding at least `required` slots, preserving the
;; first `used` records. `in-arena` restores the caller before the copy so the
;; copy cannot extend the storage arena; the stored root remains stable if the
;; allocation grows its physical segment chain.
(define (spanned-token-buffer-grow-to! [required : i64] [used : i64]) : unit
  (let
    [old-storage-arena : i64 lex-spanned-token-buffer-arena]
    [storage-root : i64
      (if (= old-storage-arena 0)
        (arena.tl_arena_make)
        old-storage-arena)]
    [new-buffer : (__tl_dyn-array token.SpannedToken)
      (in-arena
        (arena.Arena storage-root)
        (__tl_make-array
          token.SpannedToken
          (spanned-token-buffer-next-capacity required)))]
    [j : i64 0]
    (begin
      (while (< j used)
        (begin
          (set! (array-ref new-buffer j) (array-ref lex-spanned-token-buffer j))
          (set! j (+ j 1))))
      (set! lex-spanned-token-buffer-arena storage-root)
      (set! lex-spanned-token-buffer new-buffer))))

(define (spanned-token-buffer-ensure! [required : i64] [used : i64]) : unit
  (if (> required (array-length lex-spanned-token-buffer))
    (spanned-token-buffer-grow-to! required used)
    unit))

;; Unmap the dedicated growth arena and reinstall the zero-length buffer.
;;
;; No-dangling argument (the buffer array is aliased, so this needs one):
;;
;;   - `spanned-result` is the ONLY entry point that hands out this global; the
;;     plain `result`/`lex` entries allocate a fresh `token.Token` array per
;;     call (see `result` above) and never observe this storage.
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
      (begin
        ;; The sentinel remains owned by its permanent global. Reinstall only
        ;; a shared representation view; a direct RHS would move a non-Copy
        ;; dynamic array out of that global.
        (set!
          lex-spanned-token-buffer
          (unsafe
            (ptr-read (ptr-addr-of lex-spanned-token-buffer-released))))
        (set! lex-spanned-token-buffer-arena 0)
        (unsafe
          (begin
            (arena.tl_arena_destroy retire-arena)
            (arena.tl_arena_set retained-arena)))))))

(define (spanned-token-buffer-release-regrow-ok?) : bool
  (begin
    (spanned-token-buffer-release!)
    (if (and
      (= (array-length lex-spanned-token-buffer) 0)
      (= lex-spanned-token-buffer-arena 0))
      (match (spanned-result "(release-regrow)")
        [(ResultSpannedTokens.Ok tokens)
          (let
            [regrown-ok : bool
              (and
                (> (array-length tokens) 0)
                (!= lex-spanned-token-buffer-arena 0)
                (=
                  (token.tag
                    (token.spanned-token-tok (array-shared-view tokens 0)))
                  (token.tag-lparen)))]
            (begin
              (spanned-token-buffer-release!)
              (let
                [released-again-ok : bool
                  (and
                    (= (array-length lex-spanned-token-buffer) 0)
                    (= lex-spanned-token-buffer-arena 0))]
                (begin
                  ;; A release without a backing arena is idempotent.
                  (spanned-token-buffer-release!)
                  (and
                    regrown-ok
                    released-again-ok
                    (= (array-length lex-spanned-token-buffer) 0)
                    (= lex-spanned-token-buffer-arena 0))))))]
        [(ResultSpannedTokens.Err _) false])
      false)))

(define (spanned-token-buffer-arena-ownership-ok?) : bool
  (let
    [scratch : arena.Arena (arena.make)]
    [required : i64 (+ (array-length lex-spanned-token-buffer) 1)]
    [witness : token.SpannedToken
      (token.spanned-token-new token.Token.LBracket 7 11)]
    (begin
      ;; Earlier checks may intentionally release the shared storage. Keep
      ;; this ownership check independent of test order before parking slot 0.
      (spanned-token-buffer-ensure! 1 0)
      (in-arena
        scratch
        (begin
          (set! (array-ref lex-spanned-token-buffer 0) witness)
          (spanned-token-buffer-grow-to! required 1)))
      (arena.destroy-safe! scratch)
      (and
        (>= (array-length lex-spanned-token-buffer) required)
        (spanned-token-buffer-grow-preserves-records?)
        (match (spanned-result "(arena-ok)")
          [(ResultSpannedTokens.Ok tokens)
            (and
              (=
                (token.tag
                  (token.spanned-token-tok
                    (unsafe
                      (ptr-read (ptr-offset (array-data tokens) 0)))))
                (token.tag-lparen))
              (=
                (token.tag
                  (token.spanned-token-tok
                    (unsafe
                      (ptr-read (ptr-offset (array-data tokens) 3)))))
                (token.tag-end)))]
          [(ResultSpannedTokens.Err _) false])))))

;; The record the ownership check parked at slot 0 must survive the grow above:
;; mid-scan growth relies on it.
(define (spanned-token-buffer-grow-preserves-records?) : bool
  (and
    (=
      (token.tag
        (token.spanned-token-tok
          (unsafe
            (ptr-read (__tl_array-data lex-spanned-token-buffer)))))
      (token.tag-lbracket))
    (= (token.spanned-token-line (array-ref lex-spanned-token-buffer 0)) 7)
    (= (token.spanned-token-col (array-ref lex-spanned-token-buffer 0)) 11)))

;; `spanned-result : (-> String ResultSpannedTokens)` - lex into the shared
;; spanned-token buffer and hand back that buffer; slot `count` holds the
;; trailing `token.Token.End`. The buffer identity can change during the scan
;; (growth), so it is re-read from the global here rather than captured before.
(define (spanned-result-with-intern-owner
  [src : String]
  [owner : (LexerInternOwner intern-state)]) : ResultSpannedTokens
  (match (into-spanned-tokens-result-with-intern-owner (& src) owner)
    [(ResultLexIntoSpanned.Ok _)
      (ResultSpannedTokens.Ok (global-shared-view lex-spanned-token-buffer))]
    [(ResultLexIntoSpanned.Err err) (ResultSpannedTokens.Err err)]))

;; Serial/tool compatibility adapter. Compile jobs use the explicit twin below.
(define (spanned-result [src : String]) : ResultSpannedTokens
  (spanned-result-with-intern-owner src LexerInternOwner.Active))

(define (spanned-result-with-intern-state
  [src : String]
  [intern-state : (&mut intern-state ci.InternCompatState)]) : ResultSpannedTokens
  (begin
    (ci.intern-compat-state-ensure-ready! intern-state)
    (spanned-result-with-intern-owner
      src
      (LexerInternOwner.State (& intern-state)))))

(define (percent-symbol-ok?) : bool
  (match (result "(% n 16)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-shared-view toks 1)) (token.tag-sym))
        (string.eq (token.sym (array-shared-view toks 1)) "%"))]
    [(ResultTokens.Err _) false]))

(define (ampersand-symbol-ok?) : bool
  (match (result "(& r String) (&mut r String)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-shared-view toks 1)) (token.tag-sym))
        (string.eq (token.sym (array-shared-view toks 1)) "&")
        (= (token.tag (array-shared-view toks 6)) (token.tag-sym))
        (string.eq (token.sym (array-shared-view toks 6)) "&mut"))]
    [(ResultTokens.Err _) false]))

(define (float-token-ok?) : bool
  (match (result "(3.14)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-shared-view toks 1)) (token.tag-float))
        (string.eq (token.float (array-shared-view toks 1)) "3.14"))]
    [(ResultTokens.Err _) false]))

(define (negative-int-token-ok?) : bool
  (match (result "(-1 - x)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-shared-view toks 1)) (token.tag-int))
        (= (token.int (array-shared-view toks 1)) -1)
        (= (token.tag (array-shared-view toks 2)) (token.tag-sym))
        (string.eq (token.sym (array-shared-view toks 2)) "-"))]
    [(ResultTokens.Err _) false]))

(define (token-int-eq?
  [toks : (& toks (__tl_dyn-array token.Token))]
  [idx : i64]
  [value : i64]) : bool
  (let
    [tok : token.Token (token.token-copy (& (array-ref toks idx)))]
    (and
      (= (token.tag (global-shared-view tok)) (token.tag-int))
      (= (token.int tok) value))))

(define (token-sym-eq?
  [toks : (& toks (__tl_dyn-array token.Token))]
  [idx : i64]
  [value : String]) : bool
  (let
    [tok : token.Token (token.token-copy (& (array-ref toks idx)))]
    (and
      (= (token.tag (global-shared-view tok)) (token.tag-sym))
      (string.eq (token.sym tok) value))))

(define (prefixed-int-token-ok?) : bool
  (match (result "(0x2a 0x2A -0x2a 0b101010 -0b101010)")
    [(ResultTokens.Ok toks)
      (and
        (token-int-eq? (& toks) 1 42)
        (token-int-eq? (& toks) 2 42)
        (token-int-eq? (& toks) 3 -42)
        (token-int-eq? (& toks) 4 42)
        (token-int-eq? (& toks) 5 -42)
        (= (token.tag (array-shared-view toks 7)) (token.tag-end)))]
    [(ResultTokens.Err _) false]))

;; Returns 42 when the spanned lexer records correct 1-based line/column
;; positions, including a token inside a nested list and the trailing EOF.
;; Source `"(a\n  (b c))"` lexes to:
;;   0:'(' 1:1   1:'a' 1:2   2:'(' 2:3   3:'b' 2:4   4:'c' 2:6
;;   5:')' 2:7   6:')' 2:8   7:token.Token.End 2:9
(define (quote-text) : String
  "\"")

(define (backslash-text) : String
  "\\")

(define (basic-token-sequence-ok?) : bool
  (match (result "(define [x : i64] -42 \"ok\" '\\n')")
    [(ResultTokens.Ok toks)
      (let
        [ok : bool true]
        (begin
          (if (= (token.tag (array-shared-view toks 0)) (token.tag-lparen))
            unit
            (set! ok false))
          (if (= (token.tag (array-shared-view toks 1)) (token.tag-sym))
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-shared-view toks 1)) "define")
            unit
            (set! ok false))
          (if (= (token.tag (array-shared-view toks 2)) (token.tag-lbracket))
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-shared-view toks 3)) "x")
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-shared-view toks 4)) ":")
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-shared-view toks 5)) "i64")
            unit
            (set! ok false))
          (if (= (token.tag (array-shared-view toks 6)) (token.tag-rbracket))
            unit
            (set! ok false))
          (if (= (token.int (array-shared-view toks 7)) -42)
            unit
            (set! ok false))
          (if (string.eq (token.str (array-shared-view toks 8)) "ok")
            unit
            (set! ok false))
          (if (= (token.char (array-shared-view toks 9)) '\n')
            unit
            (set! ok false))
          (if (= (token.tag (array-shared-view toks 10)) (token.tag-rparen))
            unit
            (set! ok false))
          (if (= (token.tag (array-shared-view toks 11)) (token.tag-end))
            unit
            (set! ok false))
          ok))]
    [(ResultTokens.Err _) false]))

(define (colon-annotation-tokens-ok?) : bool
  (match (result
    "[x:i64] [y :i32] (:link \"m\") ( :unknown 1) (import pkg:math.core :as math)")
    [(ResultTokens.Ok toks)
      (and
        (token-sym-eq? (& toks) 1 "x")
        (token-sym-eq? (& toks) 2 ":")
        (token-sym-eq? (& toks) 3 "i64")
        (token-sym-eq? (& toks) 6 "y")
        (token-sym-eq? (& toks) 7 ":")
        (token-sym-eq? (& toks) 8 "i32")
        (token-sym-eq? (& toks) 11 ":link")
        (token-sym-eq? (& toks) 15 ":unknown")
        (token-sym-eq? (& toks) 20 "pkg:math.core")
        (token-sym-eq? (& toks) 21 ":as")
        (= (token.tag (array-shared-view toks 24)) (token.tag-end)))]
    [(ResultTokens.Err _) false]))

(define (spanned-token-sym-eq?
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [idx : i64]
  [value : String]) : bool
  (let
    [tok : token.Token (token.spanned-token-token-ref (& (array-ref toks idx)))]
    (and
      (= (token.tag (global-shared-view tok)) (token.tag-sym))
      (string.eq (token.sym tok) value))))

(define (spanned-colon-annotation-tokens-ok?) : bool
  (match (spanned-result "[x:i64] (:link \"m\")")
    [(ResultSpannedTokens.Ok toks)
      (and
        (spanned-token-sym-eq? (& toks) 1 "x")
        (spanned-token-sym-eq? (& toks) 2 ":")
        (spanned-token-sym-eq? (& toks) 3 "i64")
        (spanned-token-sym-eq? (& toks) 6 ":link")
        (=
          (token.tag (token.spanned-token-tok (array-shared-view toks 9)))
          (token.tag-end)))]
    [(ResultSpannedTokens.Err _) false]))

(define (apostrophe-char-source [body : String]) : String
  (str_cat.str-cat "'" body "'"))

(define (quote-vs-apostrophe-char-ok?) : bool
  (and
    (match (result "'form")
      [(ResultTokens.Ok toks)
        (and
          (= (token.tag (array-shared-view toks 0)) (token.tag-quote))
          (= (token.tag (array-shared-view toks 1)) (token.tag-sym))
          (string.eq (token.sym (array-shared-view toks 1)) "form")
          (= (token.tag (array-shared-view toks 2)) (token.tag-end)))]
      [(ResultTokens.Err _) false])
    (match (result "'ab'")
      [(ResultTokens.Ok toks)
        (and
          (= (token.tag (array-shared-view toks 0)) (token.tag-quote))
          (= (token.tag (array-shared-view toks 1)) (token.tag-sym))
          (string.eq (token.sym (array-shared-view toks 1)) "ab")
          (= (token.tag (array-shared-view toks 2)) (token.tag-quote))
          (= (token.tag (array-shared-view toks 3)) (token.tag-end)))]
      [(ResultTokens.Err _) false])
    (match (result "'a'")
      [(ResultTokens.Ok toks)
        (and
          (= (token.tag (array-shared-view toks 0)) (token.tag-char))
          (= (token.char (array-shared-view toks 0)) 'a')
          (= (token.tag (array-shared-view toks 1)) (token.tag-end)))]
      [(ResultTokens.Err _) false])))

(define (one-apostrophe-char-ok? [body : String] [want : char]) : bool
  (match (result (apostrophe-char-source body))
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-shared-view toks 0)) (token.tag-char))
        (= (token.char (array-shared-view toks 0)) want)
        (= (token.tag (array-shared-view toks 1)) (token.tag-end)))]
    [(ResultTokens.Err _) false]))

(define (legacy-char-rejected? [src : String]) : bool
  (match (result src)
    [(ResultTokens.Ok _) false]
    [(ResultTokens.Err message)
      (string.eq message "lexer: unexpected character")]))

(define (char-literals-ok?) : bool
  (let
    [slash : String (backslash-text)]
    (and
      (one-apostrophe-char-ok? "a" 'a')
      (one-apostrophe-char-ok? "Z" 'Z')
      (one-apostrophe-char-ok? "0" '0')
      (one-apostrophe-char-ok? "+" '+')
      (one-apostrophe-char-ok? " " ' ')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "n")
        '\n')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "t")
        '\t')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "r")
        '\r')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) "0")
        '\0')
      (one-apostrophe-char-ok?
        (str_cat.str-cat (string.copy (& slash)) (string.copy (& slash)))
        '\\')
      (one-apostrophe-char-ok? (str_cat.str-cat slash "'") '\'')
      (legacy-char-rejected? "#x'")
      (legacy-char-rejected? "#\\n'")
      (legacy-char-rejected? "#\\space'"))))

(define (error-ok?
  [src : String]
  [want-line : i64]
  [want-col : i64]
  [want-message : String]) : bool
  (match (spanned-result src)
    [(ResultSpannedTokens.Ok _) false]
    [(ResultSpannedTokens.Err err)
      (and
        (string.eq
          (token.source-error-message (global-shared-view err))
          want-message)
        (token.span-eq?
          (token.source-error-span err)
          want-line
          want-col
          want-line
          want-col))]))

(define (error-spans-ok?) : bool
  (let
    [slash : String (backslash-text)]
    (and
      (error-ok? "\n#\\bogus'" 2 1 "lexer: unexpected character")
      (error-ok?
        (apostrophe-char-source (str_cat.str-cat (string.copy (& slash)) "x"))
        1
        1
        "lexer: unknown character escape")
      (error-ok?
        (str_cat.str-cat "'" slash "n")
        1
        1
        "lexer: unterminated character literal")
      (error-ok? "ok\n@" 2 1 "lexer: unexpected character"))))

(define (prefixed-int-errors-ok?) : bool
  (and
    (error-ok? "0x" 1 1 "lexer: malformed integer literal")
    (error-ok? "0xg" 1 1 "lexer: malformed integer literal")
    (error-ok? "0b102" 1 1 "lexer: malformed integer literal")))

(define (check-prefixed-int-ok?) : bool
  (match (check "(0x2a -0b101010)")
    [(result_lex_i64.Ok _) true]
    [(result_lex_i64.Err _) false]))

(define (check-prefixed-int-error-ok?) : bool
  (match (check "0b102")
    [(result_lex_i64.Ok _) false]
    [(result_lex_i64.Err message)
      (string.eq message "lexer: malformed integer literal")]))

(define (string-source [inner : String]) : String
  (str_cat.str-cat (quote-text) inner (quote-text)))

(define (string-token-ok? [src : String] [expected : String]) : bool
  (let
    [toks : (__tl_dyn-array token.Token) (lex src)]
    (and
      (= (token.tag (array-shared-view toks 0)) (token.tag-str))
      (string.eq (token.str (array-shared-view toks 0)) expected)
      (= (token.tag (array-shared-view toks 1)) (token.tag-end)))))

(define (string-token-retains-id?) : bool
  (let
    [toks : (__tl_dyn-array token.Token) (lex (string-source "literal-id"))]
    [literal : token.Token (array-shared-view toks 0)]
    [literal-id : ci.InternId (token.str-id (global-shared-view literal))]
    (and
      (>= (ci.intern-id-value literal-id) 0)
      (string.eq (ci.intern-id-str literal-id) "literal-id")
      (ci.intern-id-eq? (token.str-id literal) literal-id))))

(define (escaped-quote-source-inner) : String
  (str_cat.str-cat
    "say "
    (backslash-text)
    (quote-text)
    "hi"
    (backslash-text)
    (quote-text)))

(define (backslash-quote-source-inner) : String
  (str_cat.str-cat
    (backslash-text)
    (backslash-text)
    (backslash-text)
    (quote-text)))

(define (string-escapes-ok?) : bool
  (let
    [slash : String (backslash-text)]
    [quote : String (quote-text)]
    (and
      (string-token-ok? (string-source "hello\\nworld") "hello\nworld")
      (string-token-ok?
        (string-source (escaped-quote-source-inner))
        (str_cat.str-cat
          "say "
          (string.copy (& quote))
          "hi"
          (string.copy (& quote))))
      (string-token-ok?
        (string-source
          (str_cat.str-cat (string.copy (& slash)) (string.copy (& slash))))
        (string.copy (& slash)))
      (string-token-ok?
        (string-source (backslash-quote-source-inner))
        (str_cat.str-cat (string.copy (& slash)) (string.copy (& quote)))))))

(define (quote-prefix-tokens-ok?) : bool
  (match (result "`(if ,x ,@xs)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-shared-view toks 0)) (token.tag-backtick))
        (= (token.tag (array-shared-view toks 3)) (token.tag-comma))
        (= (token.tag (array-shared-view toks 5)) (token.tag-comma-at))
        (= (token.tag (array-shared-view toks 7)) (token.tag-rparen))
        (= (token.tag (array-shared-view toks 8)) (token.tag-end)))]
    [(ResultTokens.Err _) false]))

(define (span-positions-ok? [s : (& s (__tl_dyn-array token.SpannedToken))]) : bool
  (let
    [ok : bool true]
    (begin
      (if (= (token.spanned-token-line (array-ref s 0)) 1)
        unit
        (set! ok false))
      (if (= (token.spanned-token-col (array-ref s 0)) 1)
        unit
        (set! ok false))
      (if (= (token.spanned-token-col (array-ref s 1)) 2)
        unit
        (set! ok false))
      (if (= (token.spanned-token-line (array-ref s 2)) 2)
        unit
        (set! ok false))
      (if (= (token.spanned-token-col (array-ref s 2)) 3)
        unit
        (set! ok false))
      (if (= (token.spanned-token-col (array-ref s 3)) 4)
        unit
        (set! ok false))
      (if (= (token.spanned-token-col (array-ref s 4)) 6)
        unit
        (set! ok false))
      (if (= (token.spanned-token-line (array-ref s 7)) 2)
        unit
        (set! ok false))
      (if (= (token.spanned-token-col (array-ref s 7)) 9)
        unit
        (set! ok false))
      (if (=
        (token.tag (token.spanned-token-token-ref (& (array-ref s 7))))
        (token.tag-end))
        unit
        (set! ok false))
      ok)))

(define (lexer-intern-owner-isolation-ok?) : bool
  (let
    [active-decoy-id : i64 (ci.intern-source-slice "lexer-active-decoy" 0 18)]
    [active-table-before : i64 (ci.intern-active-table-id)]
    [active-generation-before : i64 (ci.intern-generation)]
    [active-len-before : i64 (ci.intern-pool-len)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [source : String "(alpha : pkg/module.name \"payload\")"]
    [ids-a : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [ids-b : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [len-a : i64 0]
    [len-b : i64 0]
    [len-b-after-spanned : i64 0]
    (begin
      (match (result-with-intern-state
        (global-shared-view source)
        (&mut state-a))
        [(ResultTokens.Err _) (return false)]
        [(ResultTokens.Ok tokens)
          (begin
            (unless
              (and
                (= (token.tag (array-shared-view tokens 0)) (token.tag-lparen))
                (= (token.tag (array-shared-view tokens 5)) (token.tag-rparen))
                (= (token.tag (array-shared-view tokens 6)) (token.tag-end)))
              (return false))
            (set!
              (array-ref ids-a 0)
              (ci.intern-id-value (token.sym-id (array-shared-view tokens 1))))
            (set!
              (array-ref ids-a 1)
              (ci.intern-id-value (token.sym-id (array-shared-view tokens 2))))
            (set!
              (array-ref ids-a 2)
              (ci.intern-id-value (token.sym-id (array-shared-view tokens 3))))
            (set!
              (array-ref ids-a 3)
              (ci.intern-id-value (token.str-id (array-shared-view tokens 4))))
            (set! len-a (ci.intern-compat-state-pool-len state-a)))])
      (match (result-with-intern-state source (&mut state-b))
        [(ResultTokens.Err _) (return false)]
        [(ResultTokens.Ok tokens)
          (begin
            (set!
              (array-ref ids-b 0)
              (ci.intern-id-value (token.sym-id (array-shared-view tokens 1))))
            (set!
              (array-ref ids-b 1)
              (ci.intern-id-value (token.sym-id (array-shared-view tokens 2))))
            (set!
              (array-ref ids-b 2)
              (ci.intern-id-value (token.sym-id (array-shared-view tokens 3))))
            (set!
              (array-ref ids-b 3)
              (ci.intern-id-value (token.str-id (array-shared-view tokens 4))))
            (set! len-b (ci.intern-compat-state-pool-len state-b)))])
      (unless
        (and
          (= (array-ref ids-a 0) (array-ref ids-b 0))
          (= (array-ref ids-a 1) (array-ref ids-b 1))
          (= (array-ref ids-a 2) (array-ref ids-b 2))
          (= (array-ref ids-a 3) (array-ref ids-b 3))
          (= len-a len-b)
          (string.eq
            (ci.intern-compat-state-str state-a (array-ref ids-a 0))
            "alpha")
          (string.eq
            (ci.intern-compat-state-str state-a (array-ref ids-a 1))
            ":")
          (string.eq
            (ci.intern-compat-state-str state-a (array-ref ids-a 2))
            "pkg/module.name")
          (string.eq
            (ci.intern-compat-state-str state-a (array-ref ids-a 3))
            "payload")
          (ci.intern-compat-state-qualified? state-a (array-ref ids-a 2))
          (ci.intern-compat-state-dotted? state-a (array-ref ids-a 2))
          (string.eq
            (ci.intern-compat-state-str
              state-a
              (ci.intern-compat-state-dotted-final-id
                state-a
                (array-ref ids-a 2)))
            "name"))
        (return false))
      (match (spanned-result-with-intern-state "spanned" (&mut state-b))
        [(ResultSpannedTokens.Err _) (return false)]
        [(ResultSpannedTokens.Ok spanned)
          (let
            [spanned-token : token.Token
              (token.spanned-token-tok (array-shared-view spanned 0))]
            [spanned-id : i64
              (ci.intern-id-value
                (token.sym-id (global-shared-view spanned-token)))]
            (begin
              (unless
                (and
                  (= (token.tag spanned-token) (token.tag-sym))
                  (string.eq
                    (ci.intern-compat-state-str state-b spanned-id)
                    "spanned")
                  (=
                    (token.tag
                      (token.spanned-token-tok (array-shared-view spanned 1)))
                    (token.tag-end)))
                (return false))
              (set!
                len-b-after-spanned
                (ci.intern-compat-state-pool-len state-b))))])
      (match (result-with-intern-state "failure @" (&mut state-a))
        [(ResultTokens.Ok _) (return false)]
        [(ResultTokens.Err message)
          (unless
            (string.eq message "lexer: unexpected character")
            (return false))])
      (and
        (= (ci.intern-compat-state-pool-len state-b) len-b-after-spanned)
        (= (ci.intern-active-table-id) active-table-before)
        (= (ci.intern-generation) active-generation-before)
        (= (ci.intern-pool-len) active-len-before)
        (string.eq (ci.intern-str active-decoy-id) "lexer-active-decoy")))))

(define (span-positions-self-ok?) : bool
  (match (spanned-result "(a\n  (b c))")
    [(ResultSpannedTokens.Ok s) (span-positions-ok? (& s))]
    [(ResultSpannedTokens.Err _) false]))

(define (span-self-test) : i64
  (let
    [ok : bool true]
    (begin
      (if (span-positions-self-ok?)
        unit
        (set! ok false))
      (if (string-escapes-ok?)
        unit
        (set! ok false))
      (if (string-token-retains-id?)
        unit
        (set! ok false))
      (if (basic-token-sequence-ok?)
        unit
        (set! ok false))
      (if (colon-annotation-tokens-ok?)
        unit
        (set! ok false))
      (if (spanned-colon-annotation-tokens-ok?)
        unit
        (set! ok false))
      (if (char-literals-ok?)
        unit
        (set! ok false))
      (if (quote-vs-apostrophe-char-ok?)
        unit
        (set! ok false))
      (if (error-spans-ok?)
        unit
        (set! ok false))
      (if (percent-symbol-ok?)
        unit
        (set! ok false))
      (if (ampersand-symbol-ok?)
        unit
        (set! ok false))
      (if (float-token-ok?)
        unit
        (set! ok false))
      (if (negative-int-token-ok?)
        unit
        (set! ok false))
      (if (prefixed-int-token-ok?)
        unit
        (set! ok false))
      (if (prefixed-int-errors-ok?)
        unit
        (set! ok false))
      (if (check-prefixed-int-ok?)
        unit
        (set! ok false))
      (if (check-prefixed-int-error-ok?)
        unit
        (set! ok false))
      (if (quote-prefix-tokens-ok?)
        unit
        (set! ok false))
      (if (lexer-intern-owner-isolation-ok?)
        unit
        (set! ok false))
      (if (spanned-token-buffer-arena-ownership-ok?)
        unit
        (set! ok false))
      (if (spanned-token-buffer-release-regrow-ok?)
        unit
        (set! ok false))
      (if ok
        42
        1))))