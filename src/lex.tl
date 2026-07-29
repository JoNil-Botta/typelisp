;; lex.tl - The TypeLisp-syntax (s-expression) lexer factored out as a
;; `main`-less, importable module.
;;
;; --------------------------------------------------------------------------
;; Why this module exists (the module signal for the reader).
;; --------------------------------------------------------------------------
;; `lexer.tl` is the *demo* program for the s-expression lexer: it carries a
;; `main` that lexes a sample and tallies its symbols. But the next front-end
;; component - the s-expression *reader* in `reader.tl` - wants to REUSE the
;; lexer's `lex : (-> String (Array token.Token))` rather than re-derive it, and it
;; carries its own `main` (read tokens into a recursive `Sexpr` tree, fold it).
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

(defenum ResultTokens
  (Ok (Array token.Token))
  (Err String))

(defenum ResultSpannedTokens
  (Ok (Array token.SpannedToken))
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

(define (ok? [message : String]) : bool
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

;; The symbol-char set as two 64-bit ASCII masks: bit k of `...-mask-lo` is
;; code k, bit k of `...-mask-hi` is code 64+k. This is a static function of
;; the byte value, not a cache, and it replaces a 13-arm range-compare chain
;; that cost 204M Ir per self-compile (target/e1-notes.md, step 1.2).
;;
;; lo = {33 ! } {37 % } {38 & } {42 * } {43 + } {45 - } {46 . } {47 / }
;;      {48-57 digits} {58 : } {60 < } {61 = } {62 > } {63 ? }
;; hi = {65-90 A-Z} {95 _ } {97-122 a-z}
(define lex-symbol-char-mask-lo : i64
  -576482321629184000)
(define lex-symbol-char-mask-hi : i64
  576460745995190270)

;; `c` may appear in a symbol: a letter, a digit, or a symbol-punctuation char.
;; A symbol run is the maximal span of these starting at a non-digit symbol char.
;; `scan-symbol-end` open-codes this same test; keep the two in step.
(define (is-symbol-char [c : char]) : bool
  (let
    [code : i64 (bit-and (cast c : i64) 255)]
    (if (< code 128)
      (=
        (bit-and
          (shr
            (if (< code 64)
              lex-symbol-char-mask-lo
              lex-symbol-char-mask-hi)
            (bit-and code 63))
          1)
        1)
      false)))

;; The lexer is also used by standalone tools that do not initialize the
;; compiler builtin-ID catalog. Keep the direct builtin fast path when it is
;; available, but derive the lone-colon identity from source otherwise.
(define (colon-intern-id [src : String] [start : i64]) : ci.InternId
  (if (ci.intern-renderable-id? cbi.compiler-builtin-id-fix-colon)
    (ci.intern-id-from-renderable cbi.compiler-builtin-id-fix-colon)
    (ci.intern-source-slice-id src start 1)))

;; `c` is ASCII whitespace.
(define (is-space [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

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
          (if (is-digit (__tl_string_ref src j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

(define (scan-based-int-end [src : String] [start : i64] [n : i64] [base : i64]) : i64
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

(define (float-tail? [src : String] [int-end : i64] [n : i64]) : bool
  (if (< (+ int-end 1) n)
    (if (= (__tl_string_ref src int-end) '.')
      (is-digit (__tl_string_ref src (+ int-end 1)))
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
  (if (= (__tl_string_ref src start) '-')
    (+ start 1)
    start))

(define (number-prefixed? [src : String] [start : i64] [n : i64]) : bool
  (let
    [digits-start : i64 (number-digits-start src start)]
    (if (< (+ digits-start 1) n)
      (if (= (__tl_string_ref src digits-start) '0')
        (let
          [prefix : char (__tl_string_ref src (+ digits-start 1))]
          (or (= prefix 'x') (= prefix 'X') (= prefix 'b') (= prefix 'B')))
        false)
      false)))

(define (number-prefix-base [src : String] [start : i64]) : i64
  (let
    [prefix : char (__tl_string_ref src (+ (number-digits-start src start) 1))]
    (if (or (= prefix 'x') (= prefix 'X'))
      16
      2)))

(define (scan-prefixed-int-end-result [src : String] [start : i64] [n : i64]) : result_lex_i64.Result
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

(define (scan-number-end-result [src : String] [start : i64] [n : i64]) : result_lex_i64.Result
  (if (number-prefixed? src start n)
    (scan-prefixed-int-end-result src start n)
    (result_lex_i64.Ok (scan-number-end src start n))))

(define (parse-based-int [src : String] [start : i64] [end : i64] [base : i64]) : i64
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

(define (parse-prefixed-int [src : String] [start : i64] [end : i64]) : i64
  (let
    [digits-start : i64 (number-digits-start src start)]
    [sign : i64
      (if (= (__tl_string_ref src start) '-')
        -1
        1)]
    [base : i64 (number-prefix-base src start)]
    [value : i64 (parse-based-int src (+ digits-start 2) end base)]
    (* sign value)))

(define (number-int-value [src : String] [start : i64] [end : i64] [n : i64]) : i64
  (if (number-prefixed? src start n)
    (parse-prefixed-int src start end)
    (string.>int (string.substring src start (- end start)))))

(define (number-decimal-zero-digits? [src : String] [start : i64] [end : i64]) : bool
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
  [src : String]
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
  [src : String]
  [start : i64]
  [end : i64]
  [n : i64]) : String
  (if (number-int-text-needed? src start end n)
    (string.substring src start (- end start))
    ""))

(define (number-float? [src : String] [start : i64] [n : i64]) : bool
  (if (number-prefixed? src start n)
    false
    (float-tail? src (scan-int-end src (number-digits-start src start) n) n)))

(define (negative-number-start? [src : String] [start : i64] [n : i64]) : bool
  (if (= (__tl_string_ref src start) '-')
    (if (< (+ start 1) n)
      (is-digit (__tl_string_ref src (+ start 1)))
      false)
    false))

(define (symbol-slice-eq?
  [src : String]
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
;; This is the lexer's hottest per-byte loop (259M Ir of its own plus 204M in
;; `is-symbol-char` and a `string-ref` wrapper call per byte). The membership
;; test is open-coded from the masks above and the byte comes from the
;; `__tl_string_ref` intrinsic, which lowers to the same bounds-checked String
;; index that `string.string-ref` wraps - so this is the identical operation
;; with two calls per byte removed.
;;
;; `:` is itself a symbol char, so testing membership first and the `:` rule
;; second is equivalent to the original order: a non-`:` byte was decided by
;; `is-symbol-char` either way, and a `:` byte reaches the `pkg` rule either way.
(define (scan-symbol-end [src : String] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [code : i64 (bit-and (cast (__tl_string_ref src j) : i64) 255)]
            [member : i64
              (if (< code 128)
                (bit-and
                  (shr
                    (if (< code 64)
                      lex-symbol-char-mask-lo
                      lex-symbol-char-mask-hi)
                    (bit-and code 63))
                  1)
                0)]
            (if (= member 1)
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
(define (colon-symbol-head? [src : String] [start : i64]) : bool
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

(define (colon-token-end [src : String] [start : i64] [n : i64]) : i64
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
(define (scan-str-end-result [src : String] [start : i64] [n : i64]) : result_lex_i64.Result
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

(define (string-escape-piece [src : String] [idx : i64]) : String
  (let
    [c : char (__tl_string_ref src idx)]
    (cond
      [(= c 'n') "\n"]
      [(= c 't') "\t"]
      [(= c 'r') "\r"]
      [(= c '\\') "\\"]
      [(= c '"') "\""]
      [else (string.substring src idx 1)])))

(define (unescape-string-literal [src : String] [start : i64] [end : i64]) : String
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
(define (scan-comment-end [src : String] [start : i64] [n : i64]) : i64
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
(define (char-close-error [src : String] [idx : i64] [n : i64]) : String
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

(define (apostrophe-char-literal-result [src : String] [i : i64] [n : i64]) : ResultMaybeLexCharLiteral
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

(define (check-step [src : String] [i : i64] [n : i64]) : result_lex_i64.Result
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

(define (check-spanned [src : String]) : ResultLexCheck
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
  [src : String]
  [toks : (Array token.Token)]
  [starts : (Array i64)]) : ResultLexIntoSpanned
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
                (array-set! starts count i)
                (array-set! toks count token.Token.LParen)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c '[')
              (begin
                (array-set! starts count i)
                (array-set! toks count token.Token.LBracket)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c ')')
              (begin
                (array-set! starts count i)
                (array-set! toks count token.Token.RParen)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c ']')
              (begin
                (array-set! starts count i)
                (array-set! toks count token.Token.RBracket)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c '\'')
              (match (apostrophe-char-literal-result src i n)
                [(ResultMaybeLexCharLiteral.Ok value end)
                  (begin
                    (array-set! starts count i)
                    (array-set! toks count (token.Token.Char value))
                    (set! count (+ count 1))
                    (set! i end))]
                [(ResultMaybeLexCharLiteral.Err err)
                  (begin
                    (set! ok false)
                    (set! message err)
                    (set! err-pos i))]
                [(ResultMaybeLexCharLiteral.No)
                  (begin
                    (array-set! starts count i)
                    (array-set! toks count token.Token.Quote)
                    (set! count (+ count 1))
                    (set! i (+ i 1)))])]
            [(= c '`')
              (begin
                (array-set! starts count i)
                (array-set! toks count token.Token.Backtick)
                (set! count (+ count 1))
                (set! i (+ i 1)))]
            [(= c ',')
              (begin
                (array-set! starts count i)
                (if (< (+ i 1) n)
                  (if (= (__tl_string_ref src (+ i 1)) '@')
                    (begin
                      (array-set! toks count token.Token.CommaAt)
                      (set! i (+ i 2)))
                    (begin
                      (array-set! toks count token.Token.Comma)
                      (set! i (+ i 1))))
                  (begin
                    (array-set! toks count token.Token.Comma)
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
                        (ci.intern-source-slice-id
                          text
                          0
                          (string.string-length text))]
                      (begin
                        (array-set! starts count i)
                        (array-set! toks count (token.Token.Str string-id))
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
                    (array-set! starts count i)
                    (if (number-float? src i n)
                      (array-set!
                        toks
                        count
                        (token.Token.Float (string.substring src i (- end i))))
                      (array-set!
                        toks
                        count
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
                    (array-set! starts count i)
                    (array-set!
                      toks
                      count
                      (token.Token.Sym
                        (ci.intern-source-slice-id src i (- end i))))
                    (set! count (+ count 1))
                    (set! i end))
                  (begin
                    (array-set! starts count i)
                    (array-set!
                      toks
                      count
                      (token.Token.Sym (colon-intern-id src i)))
                    (set! count (+ count 1))
                    (set! i (+ i 1)))))]
            [(is-symbol-char c)
              (let
                [end : i64 (scan-symbol-end src i n)]
                (begin
                  (array-set! starts count i)
                  (array-set!
                    toks
                    count
                    (token.Token.Sym
                      (ci.intern-source-slice-id src i (- end i))))
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
          (array-set! toks count token.Token.End)
          (ResultLexIntoSpanned.Ok count))
        (ResultLexIntoSpanned.Err (source-error-at src err-pos message))))))

(defenum LexPosition
  (Position i64 i64))

(define (advance-position
  [src : String]
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
;; `stoks`/`limit` mirror the global buffer and are refreshed whenever it moves;
;; the guard at the top of the loop reserves room for this iteration's token AND
;; the trailing `token.Token.End`, so every `array-set!` below is in range
;; without a per-write capacity test.
(define (into-spanned-tokens-result [src : String]) : ResultLexIntoSpanned
  (let
    [i : i64 0]
    [n : i64 (string.string-length src)]
    [count : i64 0]
    [line : i64 1]
    [col : i64 1]
    [ok : bool true]
    [message : String ""]
    [err-pos : i64 0]
    [stoks : (Array token.SpannedToken) lex-spanned-token-buffer]
    [limit : i64 (array-length stoks)]
    (begin
      (cfg compile-profile (ci.intern-profile-note-source-bytes n))
      (while (and (< i n) ok)
        (begin
          (if (> (+ count 2) limit)
            (begin
              (spanned-token-buffer-ensure! (+ count 2) count)
              (set! stoks lex-spanned-token-buffer)
              (set! limit (array-length stoks)))
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
                  (array-set!
                    stoks
                    count
                    (token.spanned-token-new token.Token.LParen line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c '[')
                (begin
                  (array-set!
                    stoks
                    count
                    (token.spanned-token-new token.Token.LBracket line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c ')')
                (begin
                  (array-set!
                    stoks
                    count
                    (token.spanned-token-new token.Token.RParen line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c ']')
                (begin
                  (array-set!
                    stoks
                    count
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
                        (array-set!
                          stoks
                          count
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
                        (array-set!
                          stoks
                          count
                          (token.spanned-token-new token.Token.Quote line col))
                        (set! count (+ count 1))
                        (set! i (+ i 1))
                        (set! col (+ col 1)))]))]
              [(= c '`')
                (begin
                  (array-set!
                    stoks
                    count
                    (token.spanned-token-new token.Token.Backtick line col))
                  (set! count (+ count 1))
                  (set! i (+ i 1))
                  (set! col (+ col 1)))]
              [(= c ',')
                (begin
                  (if (< (+ i 1) n)
                    (if (= (__tl_string_ref src (+ i 1)) '@')
                      (begin
                        (array-set!
                          stoks
                          count
                          (token.spanned-token-new token.Token.CommaAt line col))
                        (set! i (+ i 2))
                        (set! col (+ col 2)))
                      (begin
                        (array-set!
                          stoks
                          count
                          (token.spanned-token-new token.Token.Comma line col))
                        (set! i (+ i 1))
                        (set! col (+ col 1))))
                    (begin
                      (array-set!
                        stoks
                        count
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
                          (ci.intern-source-slice-id
                            text
                            0
                            (string.string-length text))]
                        (begin
                          (array-set!
                            stoks
                            count
                            (token.spanned-token-new
                              (token.Token.Str string-id)
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
                        (if (number-float? src i n)
                          (array-set!
                            stoks
                            count
                            (token.spanned-token-new
                              (token.Token.Float
                                (string.substring src i (- end i)))
                              token-line
                              token-col))
                          (array-set!
                            stoks
                            count
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
                      (array-set!
                        stoks
                        count
                        (token.spanned-token-new
                          (token.Token.Sym
                            (ci.intern-source-slice-id src i (- end i)))
                          line
                          col))
                      (set! count (+ count 1))
                      (set! col (+ col (- end i)))
                      (set! i end))
                    (begin
                      (array-set!
                        stoks
                        count
                        (token.spanned-token-new
                          (token.Token.Sym (colon-intern-id src i))
                          line
                          col))
                      (set! count (+ count 1))
                      (set! col (+ col 1))
                      (set! i (+ i 1)))))]
              [(is-symbol-char c)
                (let
                  [end : i64 (scan-symbol-end src i n)]
                  (begin
                    (array-set!
                      stoks
                      count
                      (token.spanned-token-new
                        (token.Token.Sym
                          (ci.intern-source-slice-id src i (- end i)))
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
              (set! stoks lex-spanned-token-buffer))
            unit)
          (array-set!
            stoks
            count
            (token.spanned-token-new token.Token.End line col))
          (ResultLexIntoSpanned.Ok count))
        (ResultLexIntoSpanned.Err (source-error-at src err-pos message))))))

;; `lex : (-> String (Array token.Token))` - the public entry point. Size the token
;; array by an upper bound (every char yields at most one token, plus the
;; `token.Token.End` sentinel), lex into it, then return that exact array. The trailing
;; `token.Token.End` marks
;; the logical end even though the backing array may be larger.
(define (result [src : String]) : ResultTokens
  (let
    [cap : i64 (+ (string.string-length src) 1)]
    [toks : (Array token.Token) (make-array token.Token cap)]
    [starts : (Array i64) (make-array i64 cap)]
    (match (into-spanned-result src toks starts)
      [(ResultLexIntoSpanned.Ok _) (ResultTokens.Ok toks)]
      [(ResultLexIntoSpanned.Err err)
        (ResultTokens.Err (token.source-error-message err))])))

(define (lex [src : String]) : (Array token.Token)
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
(define (index-line [src : String] [idx : i64]) : i64
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
(define (index-col [src : String] [idx : i64]) : i64
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

(define (source-error-at [src : String] [idx : i64] [message : String]) : token.SourceError
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
;; in one dedicated arena that is created once and never reset, so a grow while
;; a transient driver arena is active cannot leave this global pointing at
;; reclaimed storage.
(define lex-spanned-token-buffer : (Array token.SpannedToken)
  (make-array token.SpannedToken 0))
(define lex-spanned-token-buffer-arena : i64
  0)

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
;; first `used` records. The arena is restored before the copy so the copy
;; cannot extend the storage arena.
(define (spanned-token-buffer-grow-to! [required : i64] [used : i64]) : unit
  (let
    [previous-arena : i64 (arena.tl_arena_current)]
    [old-storage-arena : i64 lex-spanned-token-buffer-arena]
    [old-buffer : (Array token.SpannedToken) lex-spanned-token-buffer]
    [storage-root : i64
      (if (= old-storage-arena 0)
        (arena.tl_arena_make)
        old-storage-arena)]
    [_set-arena : unit
      (unsafe
        (arena.tl_arena_set storage-root))]
    [new-buffer : (Array token.SpannedToken)
      (make-array
        token.SpannedToken
        (spanned-token-buffer-next-capacity required))]
    [new-storage-arena : i64 (arena.tl_arena_current)]
    [j : i64 0]
    (begin
      (unsafe
        (arena.tl_arena_set
          (if (= previous-arena old-storage-arena)
            new-storage-arena
            previous-arena)))
      (while (< j used)
        (begin
          (array-set! new-buffer j (array-ref old-buffer j))
          (set! j (+ j 1))))
      (set! lex-spanned-token-buffer-arena new-storage-arena)
      (set! lex-spanned-token-buffer new-buffer))))

(define (spanned-token-buffer-ensure! [required : i64] [used : i64]) : unit
  (if (> required (array-length lex-spanned-token-buffer))
    (spanned-token-buffer-grow-to! required used)
    unit))

(define (spanned-token-buffer-arena-ownership-ok?) : bool
  (let
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [required : i64 (+ (array-length lex-spanned-token-buffer) 1)]
    [witness : token.SpannedToken
      (token.spanned-token-new token.Token.LBracket 7 11)]
    (begin
      (unsafe
        (arena.set! scratch))
      (array-set! lex-spanned-token-buffer 0 witness)
      (spanned-token-buffer-grow-to! required 1)
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy scratch)))
      (and
        (>= (array-length lex-spanned-token-buffer) required)
        (spanned-token-buffer-grow-preserves-records?)
        (match (spanned-result "(arena-ok)")
          [(ResultSpannedTokens.Ok tokens)
            (and
              (=
                (token.tag (token.spanned-token-tok (array-ref tokens 0)))
                (token.tag-lparen))
              (=
                (token.tag (token.spanned-token-tok (array-ref tokens 3)))
                (token.tag-end)))]
          [(ResultSpannedTokens.Err _) false])))))

;; The record the ownership check parked at slot 0 must survive the grow above:
;; mid-scan growth relies on it.
(define (spanned-token-buffer-grow-preserves-records?) : bool
  (let
    [kept : token.SpannedToken (array-ref lex-spanned-token-buffer 0)]
    (and
      (= (token.tag (token.spanned-token-tok kept)) (token.tag-lbracket))
      (= (token.spanned-token-line kept) 7)
      (= (token.spanned-token-col kept) 11))))

;; `spanned-result : (-> String ResultSpannedTokens)` - lex into the shared
;; spanned-token buffer and hand back that buffer; slot `count` holds the
;; trailing `token.Token.End`. The buffer identity can change during the scan
;; (growth), so it is re-read from the global here rather than captured before.
(define (spanned-result [src : String]) : ResultSpannedTokens
  (match (into-spanned-tokens-result src)
    [(ResultLexIntoSpanned.Ok _)
      (ResultSpannedTokens.Ok lex-spanned-token-buffer)]
    [(ResultLexIntoSpanned.Err err) (ResultSpannedTokens.Err err)]))

(define (percent-symbol-ok?) : bool
  (match (result "(% n 16)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-ref toks 1)) (token.tag-sym))
        (string.eq (token.sym (array-ref toks 1)) "%"))]
    [(ResultTokens.Err _) false]))

(define (ampersand-symbol-ok?) : bool
  (match (result "(& r String) (&mut r String)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-ref toks 1)) (token.tag-sym))
        (string.eq (token.sym (array-ref toks 1)) "&")
        (= (token.tag (array-ref toks 6)) (token.tag-sym))
        (string.eq (token.sym (array-ref toks 6)) "&mut"))]
    [(ResultTokens.Err _) false]))

(define (float-token-ok?) : bool
  (match (result "(3.14)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-ref toks 1)) (token.tag-float))
        (string.eq (token.float (array-ref toks 1)) "3.14"))]
    [(ResultTokens.Err _) false]))

(define (negative-int-token-ok?) : bool
  (match (result "(-1 - x)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-ref toks 1)) (token.tag-int))
        (= (token.int (array-ref toks 1)) -1)
        (= (token.tag (array-ref toks 2)) (token.tag-sym))
        (string.eq (token.sym (array-ref toks 2)) "-"))]
    [(ResultTokens.Err _) false]))

(define (token-int-eq? [toks : (Array token.Token)] [idx : i64] [value : i64]) : bool
  (and
    (= (token.tag (array-ref toks idx)) (token.tag-int))
    (= (token.int (array-ref toks idx)) value)))

(define (token-sym-eq?
  [toks : (Array token.Token)]
  [idx : i64]
  [value : String]) : bool
  (and
    (= (token.tag (array-ref toks idx)) (token.tag-sym))
    (string.eq (token.sym (array-ref toks idx)) value)))

(define (prefixed-int-token-ok?) : bool
  (match (result "(0x2a 0x2A -0x2a 0b101010 -0b101010)")
    [(ResultTokens.Ok toks)
      (and
        (token-int-eq? toks 1 42)
        (token-int-eq? toks 2 42)
        (token-int-eq? toks 3 -42)
        (token-int-eq? toks 4 42)
        (token-int-eq? toks 5 -42)
        (= (token.tag (array-ref toks 7)) (token.tag-end)))]
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
          (if (= (token.tag (array-ref toks 0)) (token.tag-lparen))
            unit
            (set! ok false))
          (if (= (token.tag (array-ref toks 1)) (token.tag-sym))
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-ref toks 1)) "define")
            unit
            (set! ok false))
          (if (= (token.tag (array-ref toks 2)) (token.tag-lbracket))
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-ref toks 3)) "x")
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-ref toks 4)) ":")
            unit
            (set! ok false))
          (if (string.eq (token.sym (array-ref toks 5)) "i64")
            unit
            (set! ok false))
          (if (= (token.tag (array-ref toks 6)) (token.tag-rbracket))
            unit
            (set! ok false))
          (if (= (token.int (array-ref toks 7)) -42)
            unit
            (set! ok false))
          (if (string.eq (token.str (array-ref toks 8)) "ok")
            unit
            (set! ok false))
          (if (= (token.char (array-ref toks 9)) '\n')
            unit
            (set! ok false))
          (if (= (token.tag (array-ref toks 10)) (token.tag-rparen))
            unit
            (set! ok false))
          (if (= (token.tag (array-ref toks 11)) (token.tag-end))
            unit
            (set! ok false))
          ok))]
    [(ResultTokens.Err _) false]))

(define (colon-annotation-tokens-ok?) : bool
  (match (result
    "[x:i64] [y :i32] (:link \"m\") ( :unknown 1) (import pkg:math.core :as math)")
    [(ResultTokens.Ok toks)
      (and
        (token-sym-eq? toks 1 "x")
        (token-sym-eq? toks 2 ":")
        (token-sym-eq? toks 3 "i64")
        (token-sym-eq? toks 6 "y")
        (token-sym-eq? toks 7 ":")
        (token-sym-eq? toks 8 "i32")
        (token-sym-eq? toks 11 ":link")
        (token-sym-eq? toks 15 ":unknown")
        (token-sym-eq? toks 20 "pkg:math.core")
        (token-sym-eq? toks 21 ":as")
        (= (token.tag (array-ref toks 24)) (token.tag-end)))]
    [(ResultTokens.Err _) false]))

(define (spanned-token-sym-eq?
  [toks : (Array token.SpannedToken)]
  [idx : i64]
  [value : String]) : bool
  (let
    [tok : token.Token (token.spanned-token-tok (array-ref toks idx))]
    (and (= (token.tag tok) (token.tag-sym)) (string.eq (token.sym tok) value))))

(define (spanned-colon-annotation-tokens-ok?) : bool
  (match (spanned-result "[x:i64] (:link \"m\")")
    [(ResultSpannedTokens.Ok toks)
      (and
        (spanned-token-sym-eq? toks 1 "x")
        (spanned-token-sym-eq? toks 2 ":")
        (spanned-token-sym-eq? toks 3 "i64")
        (spanned-token-sym-eq? toks 6 ":link")
        (=
          (token.tag (token.spanned-token-tok (array-ref toks 9)))
          (token.tag-end)))]
    [(ResultSpannedTokens.Err _) false]))

(define (apostrophe-char-source [body : String]) : String
  (string.append "'" (string.append body "'")))

(define (quote-vs-apostrophe-char-ok?) : bool
  (and
    (match (result "'form")
      [(ResultTokens.Ok toks)
        (and
          (= (token.tag (array-ref toks 0)) (token.tag-quote))
          (= (token.tag (array-ref toks 1)) (token.tag-sym))
          (string.eq (token.sym (array-ref toks 1)) "form")
          (= (token.tag (array-ref toks 2)) (token.tag-end)))]
      [(ResultTokens.Err _) false])
    (match (result "'ab'")
      [(ResultTokens.Ok toks)
        (and
          (= (token.tag (array-ref toks 0)) (token.tag-quote))
          (= (token.tag (array-ref toks 1)) (token.tag-sym))
          (string.eq (token.sym (array-ref toks 1)) "ab")
          (= (token.tag (array-ref toks 2)) (token.tag-quote))
          (= (token.tag (array-ref toks 3)) (token.tag-end)))]
      [(ResultTokens.Err _) false])
    (match (result "'a'")
      [(ResultTokens.Ok toks)
        (and
          (= (token.tag (array-ref toks 0)) (token.tag-char))
          (= (token.char (array-ref toks 0)) 'a')
          (= (token.tag (array-ref toks 1)) (token.tag-end)))]
      [(ResultTokens.Err _) false])))

(define (one-apostrophe-char-ok? [body : String] [want : char]) : bool
  (match (result (apostrophe-char-source body))
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-ref toks 0)) (token.tag-char))
        (= (token.char (array-ref toks 0)) want)
        (= (token.tag (array-ref toks 1)) (token.tag-end)))]
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
      (one-apostrophe-char-ok? (string.append slash "n") '\n')
      (one-apostrophe-char-ok? (string.append slash "t") '\t')
      (one-apostrophe-char-ok? (string.append slash "r") '\r')
      (one-apostrophe-char-ok? (string.append slash "0") '\0')
      (one-apostrophe-char-ok? (string.append slash slash) '\\')
      (one-apostrophe-char-ok? (string.append slash "'") '\'')
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
        (string.eq (token.source-error-message err) want-message)
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
        (apostrophe-char-source (string.append slash "x"))
        1
        1
        "lexer: unknown character escape")
      (error-ok?
        (string.append "'" (string.append slash "n"))
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
  (string.append (quote-text) (string.append inner (quote-text))))

(define (string-token-ok? [src : String] [expected : String]) : bool
  (let
    [toks : (Array token.Token) (lex src)]
    (and
      (= (token.tag (array-ref toks 0)) (token.tag-str))
      (string.eq (token.str (array-ref toks 0)) expected)
      (= (token.tag (array-ref toks 1)) (token.tag-end)))))

(define (string-token-retains-id?) : bool
  (let
    [toks : (Array token.Token) (lex (string-source "literal-id"))]
    [literal : token.Token (array-ref toks 0)]
    [literal-id : i64 (token.str-id literal)]
    (and
      (>= literal-id 0)
      (string.eq (ci.intern-str literal-id) "literal-id")
      (= (token.str-id literal) literal-id))))

(define (escaped-quote-source-inner) : String
  (string.append
    "say "
    (string.append
      (backslash-text)
      (string.append
        (quote-text)
        (string.append "hi" (string.append (backslash-text) (quote-text)))))))

(define (backslash-quote-source-inner) : String
  (string.append
    (backslash-text)
    (string.append
      (backslash-text)
      (string.append (backslash-text) (quote-text)))))

(define (string-escapes-ok?) : bool
  (let
    [slash : String (backslash-text)]
    [quote : String (quote-text)]
    (and
      (string-token-ok? (string-source "hello\\nworld") "hello\nworld")
      (string-token-ok?
        (string-source (escaped-quote-source-inner))
        (string.append "say " (string.append quote (string.append "hi" quote))))
      (string-token-ok? (string-source (string.append slash slash)) slash)
      (string-token-ok?
        (string-source (backslash-quote-source-inner))
        (string.append slash quote)))))

(define (quote-prefix-tokens-ok?) : bool
  (match (result "`(if ,x ,@xs)")
    [(ResultTokens.Ok toks)
      (and
        (= (token.tag (array-ref toks 0)) (token.tag-backtick))
        (= (token.tag (array-ref toks 3)) (token.tag-comma))
        (= (token.tag (array-ref toks 5)) (token.tag-comma-at))
        (= (token.tag (array-ref toks 7)) (token.tag-rparen))
        (= (token.tag (array-ref toks 8)) (token.tag-end)))]
    [(ResultTokens.Err _) false]))

(define (span-positions-ok? [s : (Array token.SpannedToken)]) : bool
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
        (token.tag (token.spanned-token-tok (array-ref s 7)))
        (token.tag-end))
        unit
        (set! ok false))
      ok)))

(define (span-self-test) : i64
  (match (spanned-result "(a\n  (b c))")
    [(ResultSpannedTokens.Ok s)
      (let
        [ok : bool true]
        (begin
          (if (span-positions-ok? s)
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
          (if (spanned-token-buffer-arena-ownership-ok?)
            unit
            (set! ok false))
          (if ok
            42
            1)))]
    [(ResultSpannedTokens.Err _) 2]))