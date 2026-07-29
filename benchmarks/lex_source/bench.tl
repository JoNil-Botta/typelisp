;# benchmarks/lex_source/bench.tl - the compiler's own tokenizer hot loop.
;#
;# Equivalent to benchmarks/lex_source/baseline.c. The kernel is extracted from
;# the self-hosting front end's lexer and the input is REAL compiler source: the
;# corpus in benchmarks/lex_source/data/corpus.tl-txt is a byte-for-byte
;# concatenation of src/lex.tl, src/compiler_liveness.tl, src/compiler_symbols.tl
;# and src/compiler_lower.tl, produced by
;# benchmarks/lex_source/tools/export_corpus.py. So the byte-class dispatch here
;# runs on exactly the text the compiler's lexer walks when it compiles itself,
;# with that text's real distribution of dashed symbols, keyword annotations,
;# numeric literals, escaped string literals, comment blocks, and nesting.
;#
;# What it mirrors, function for function:
;#   src/lex.tl `into-spanned-tokens-result`  the main `cond` dispatch over
;#     the byte under the cursor, in its source order (whitespace, `(`, `[`,
;#     `)`, `]`, `'`, backtick, `,`, `"`, `;`, digit-or-negative-number, `:`,
;#     symbol char, else), together with its 1-based line/column tracking.
;#   src/lex.tl `is-space`, `is-digit`, `is-hex-digit`, `is-binary-digit`,
;#     `is-symbol-char`  the byte classifiers, with `is-symbol-char`'s exact
;#     code ranges (letters, digits, `-`, `_`, `!`, `%`, `&`, `*`, `+`, `.`,
;#     `/`, `:`, `<`, `=`, `>`, `?`), which is what makes dashed symbols such
;#     as `compiler-live-set-word-at` a single token.
;#   src/lex.tl `scan-symbol-end` including its `:` rule and the `pkg` slice
;#     exception (`symbol-slice-eq?`), `scan-int-end`, `scan-based-int-end`,
;#     `float-tail?`, `number-digits-start`, `number-prefixed?`,
;#     `number-prefix-base`, `scan-number-end`, `number-float?`,
;#     `negative-number-start?`, `scan-str-end-result`, `scan-comment-end`,
;#     `colon-symbol-head?`, `colon-token-end`,
;#     `apostrophe-char-literal-result`, `apostrophe-escaped-char-result`,
;#     `advance-position`.
;#   src/token.tl `tag` and the `tag-*` constants  the token-kind numbering
;#     (LParen 1, RParen 2, Int 3, Sym 4, End 5, Str 6, Char 7, Float 8,
;#     LBracket 9, RBracket 10, Quote 11, Backtick 12, Comma 13, CommaAt 14),
;#     which is the number folded into the checksum as the token's kind.
;#   src/read.tl `peek-tag` / `form-result`  the reason the kind tag is
;#     the observable: the reader classifies each token by `token.tag` alone,
;#     so a kind-plus-extent fold is exactly what the consumer sees.
;#
;# What it deliberately leaves out, because it is allocation rather than
;# classification: the `Result`/`SourceError` plumbing of the scanners that can
;# fail (the corpus is real source the compiler already lexes cleanly, so those
;# arms are unreachable), building the `(Array token.SpannedToken)` output,
;# interning symbol and string lexemes (that path is benchmarks/intern_table),
;# converting integer literals to values, and unescaping string literals into a
;# TextBuf. The corpus is copied once into an `(Array u8)` rather than being
;# walked as the compiler's `String`, so the row measures byte-class dispatch
;# and not `string.string-ref` dispatch.
;#
;# The corpus is loaded once and tokenized `rounds` times. Every token folds its
;# (kind, length, first byte) into a wrapping 64-bit accumulator; after each
;# pass the final line, column, and token count fold in too, which keeps the
;# position recurrence observable. The corpus path and round count are runtime
;# arguments, so nothing can be constant folded. All arithmetic wraps modulo
;# 2^64 in both languages, so the printed decimal matches the C baseline's
;# `%lld`.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

;; Token-kind tags, kept in the numbering of src/token.tl `tag`.
(define ls-tag-lparen : i64
  1)
(define ls-tag-rparen : i64
  2)
(define ls-tag-int : i64
  3)
(define ls-tag-sym : i64
  4)
(define ls-tag-str : i64
  6)
(define ls-tag-char : i64
  7)
(define ls-tag-float : i64
  8)
(define ls-tag-lbracket : i64
  9)
(define ls-tag-rbracket : i64
  10)
(define ls-tag-quote : i64
  11)
(define ls-tag-backtick : i64
  12)
(define ls-tag-comma : i64
  13)
(define ls-tag-comma-at : i64
  14)

;; Contribution of a byte no arm of the dispatch accepts. In the compiler this
;; is the recoverable "lexer: unexpected character" diagnostic; here it keeps
;; the dispatch's shape and absorbs any non-ASCII byte outside a literal.
(define ls-tag-unexpected : i64
  99)

;; ---- byte classifiers (src/lex.tl) ----
(define (ls-digit? [c : i64]) : bool
  (and (>= c 48) (<= c 57)))

(define (ls-hex-digit? [c : i64]) : bool
  (or (ls-digit? c) (and (>= c 97) (<= c 102)) (and (>= c 65) (<= c 70))))

(define (ls-binary-digit? [c : i64]) : bool
  (or (= c 48) (= c 49)))

;; `is-symbol-char`: a letter, a digit, or one of the symbol-punctuation codes.
(define (ls-symbol-char? [c : i64]) : bool
  (cond
    [(and (>= c 97) (<= c 122)) true]
    [(and (>= c 65) (<= c 90)) true]
    [(and (>= c 48) (<= c 57)) true]
    [(= c 45) true]
    [(= c 95) true]
    [(= c 33) true]
    [(and (>= c 37) (<= c 38)) true]
    [(= c 42) true]
    [(= c 43) true]
    [(= c 46) true]
    [(= c 47) true]
    [(= c 58) true]
    [(and (>= c 60) (<= c 63)) true]
    [else false]))

(define (ls-space? [c : i64]) : bool
  (or (= c 32) (= c 9) (= c 10) (= c 13)))

(define (ls-byte [buf : (Array u8)] [index : i64]) : i64
  (cast (array-ref buf index) : i64))

;; ---- scanners (src/lex.tl) ----
;; `scan-int-end`: the digit run starting at `start`. The bounds check is kept
;; outside the element read, matching the lexer's discipline.
(define (ls-scan-int-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (ls-digit? (ls-byte buf j))
            (set! j (+ j 1))
            (set! keep false))
          (set! keep false)))
      j)))

(define (ls-scan-based-int-end
  [buf : (Array u8)]
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
            [c : i64 (ls-byte buf j)]
            (if (if (= base 16)
              (ls-hex-digit? c)
              (ls-binary-digit? c))
              (set! j (+ j 1))
              (set! keep false)))
          (set! keep false)))
      j)))

(define (ls-float-tail? [buf : (Array u8)] [int-end : i64] [n : i64]) : bool
  (if (< (+ int-end 1) n)
    (if (= (ls-byte buf int-end) 46)
      (ls-digit? (ls-byte buf (+ int-end 1)))
      false)
    false))

(define (ls-number-digits-start [buf : (Array u8)] [start : i64]) : i64
  (if (= (ls-byte buf start) 45)
    (+ start 1)
    start))

(define (ls-number-prefixed? [buf : (Array u8)] [start : i64] [n : i64]) : bool
  (let
    [digits-start : i64 (ls-number-digits-start buf start)]
    (if (< (+ digits-start 1) n)
      (if (= (ls-byte buf digits-start) 48)
        (let
          [prefix : i64 (ls-byte buf (+ digits-start 1))]
          (or (= prefix 120) (= prefix 88) (= prefix 98) (= prefix 66)))
        false)
      false)))

(define (ls-number-prefix-base [buf : (Array u8)] [start : i64]) : i64
  (let
    [prefix : i64 (ls-byte buf (+ (ls-number-digits-start buf start) 1))]
    (if (or (= prefix 120) (= prefix 88))
      16
      2)))

(define (ls-scan-decimal-number-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [digits-start : i64 (ls-number-digits-start buf start)]
    [int-end : i64 (ls-scan-int-end buf digits-start n)]
    (if (ls-float-tail? buf int-end n)
      (ls-scan-int-end buf (+ int-end 1) n)
      int-end)))

(define (ls-scan-prefixed-int-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [digits-start : i64 (ls-number-digits-start buf start)]
    [base : i64 (ls-number-prefix-base buf start)]
    (ls-scan-based-int-end buf (+ digits-start 2) n base)))

(define (ls-scan-number-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (if (ls-number-prefixed? buf start n)
    (ls-scan-prefixed-int-end buf start n)
    (ls-scan-decimal-number-end buf start n)))

;; `number-float?`: a prefixed literal is never a float, otherwise the integer
;; run is rescanned to look for a `.digit` tail. The rescan is the lexer's.
(define (ls-number-float? [buf : (Array u8)] [start : i64] [n : i64]) : bool
  (if (ls-number-prefixed? buf start n)
    false
    (ls-float-tail?
      buf
      (ls-scan-int-end buf (ls-number-digits-start buf start) n)
      n)))

(define (ls-negative-number-start? [buf : (Array u8)] [start : i64] [n : i64]) : bool
  (if (= (ls-byte buf start) 45)
    (if (< (+ start 1) n)
      (ls-digit? (ls-byte buf (+ start 1)))
      false)
    false))

;; `symbol-slice-eq?` at its two call sites: the `pkg` prefix that lets a `:`
;; continue a symbol run, and the `:as` import keyword.
(define (ls-slice-pkg? [buf : (Array u8)] [start : i64] [end : i64]) : bool
  (if (= (- end start) 3)
    (and
      (= (ls-byte buf start) 112)
      (= (ls-byte buf (+ start 1)) 107)
      (= (ls-byte buf (+ start 2)) 103))
    false))

(define (ls-slice-colon-as? [buf : (Array u8)] [start : i64] [end : i64]) : bool
  (if (= (- end start) 3)
    (and
      (= (ls-byte buf start) 58)
      (= (ls-byte buf (+ start 1)) 97)
      (= (ls-byte buf (+ start 2)) 115))
    false))

(define (ls-scan-symbol-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : i64 (ls-byte buf j)]
            (if (and (= c 58) (> j start) (not (ls-slice-pkg? buf start j)))
              (set! keep false)
              (if (ls-symbol-char? c)
                (set! j (+ j 1))
                (set! keep false))))
          (set! keep false)))
      j)))

;; `colon-symbol-head?`: a `:` opens a keyword symbol only when the first
;; non-space byte before it is `(`, so annotations stay standalone `:` tokens.
(define (ls-colon-symbol-head? [buf : (Array u8)] [start : i64]) : bool
  (let
    [j : i64 (- start 1)]
    [keep : bool true]
    [result : bool true]
    (begin
      (while keep
        (if (< j 0)
          (set! keep false)
          (let
            [c : i64 (ls-byte buf j)]
            (if (ls-space? c)
              (set! j (- j 1))
              (begin
                (set! result (= c 40))
                (set! keep false))))))
      result)))

(define (ls-colon-token-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [end : i64 (ls-scan-symbol-end buf start n)]
    (if (or
      (ls-colon-symbol-head? buf start)
      (ls-slice-colon-as? buf start end))
      end
      (+ start 1))))

;; `scan-str-end-result`: forward to the first unescaped `"`. A backslash
;; escapes the following byte, so `\"` stays inside the literal.
(define (ls-scan-str-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (let
            [c : i64 (ls-byte buf j)]
            (if (= c 34)
              (set! keep false)
              (if (= c 92)
                (if (< (+ j 1) n)
                  (set! j (+ j 2))
                  (set! keep false))
                (set! j (+ j 1)))))
          (set! keep false)))
      j)))

(define (ls-scan-comment-end [buf : (Array u8)] [start : i64] [n : i64]) : i64
  (let
    [j : i64 start]
    [keep : bool true]
    (begin
      (while keep
        (if (< j n)
          (if (= (ls-byte buf j) 10)
            (set! keep false)
            (set! j (+ j 1)))
          (set! keep false)))
      j)))

;; `apostrophe-escaped-char-result`: the escapes a character literal accepts.
(define (ls-escaped-char? [c : i64]) : bool
  (or (= c 110) (= c 116) (= c 114) (= c 48) (= c 92) (= c 39)))

;; `apostrophe-char-literal-result`, collapsed to the end index of the literal
;; or -1 for "this apostrophe is a quote prefix, not a character literal".
(define (ls-apostrophe-char-end [buf : (Array u8)] [i : i64] [n : i64]) : i64
  (if (< (+ i 1) n)
    (let
      [payload : i64 (ls-byte buf (+ i 1))]
      (cond
        [(= payload 92)
          (let
            [esc-idx : i64 (+ i 2)]
            (if (< esc-idx n)
              (if (ls-escaped-char? (ls-byte buf esc-idx))
                (if (and (< (+ i 3) n) (= (ls-byte buf (+ i 3)) 39))
                  (+ i 4)
                  -1)
                -1)
              -1))]
        [(or (= payload 39) (= payload 10) (= payload 13)) -1]
        [else
          (if (< (+ i 2) n)
            (if (= (ls-byte buf (+ i 2)) 39)
              (+ i 3)
              -1)
            -1)]))
    -1))

;; ---- the fold ----
;; Every token contributes its kind, its byte length, and its first byte. All
;; three products wrap modulo 2^64, matching the C baseline's uint64_t.
(define (ls-fold [acc : i64] [kind : i64] [length : i64] [first : i64]) : i64
  (+ (* acc 1000003) (+ (* kind 1315423911) (+ (* length 2654435761) first))))

;; ---- the tokenizer ----
;; One pass over the corpus. Line and column advance exactly as they do in
;; `into-spanned-tokens-result`, including the `advance-position` rescan
;; a string literal needs because it may contain newlines.
(define (ls-tokenize [buf : (Array u8)] [n : i64] [seed-acc : i64]) : i64
  (let
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    [count : i64 0]
    [acc : i64 seed-acc]
    (begin
      (while (< i n)
        (let
          [c : i64 (ls-byte buf i)]
          (cond
            [(ls-space? c)
              (begin
                (if (= c 10)
                  (begin
                    (set! line (+ line 1))
                    (set! col 1))
                  (set! col (+ col 1)))
                (set! i (+ i 1)))]
            [(= c 40)
              (begin
                (set! acc (ls-fold acc ls-tag-lparen 1 c))
                (set! count (+ count 1))
                (set! i (+ i 1))
                (set! col (+ col 1)))]
            [(= c 91)
              (begin
                (set! acc (ls-fold acc ls-tag-lbracket 1 c))
                (set! count (+ count 1))
                (set! i (+ i 1))
                (set! col (+ col 1)))]
            [(= c 41)
              (begin
                (set! acc (ls-fold acc ls-tag-rparen 1 c))
                (set! count (+ count 1))
                (set! i (+ i 1))
                (set! col (+ col 1)))]
            [(= c 93)
              (begin
                (set! acc (ls-fold acc ls-tag-rbracket 1 c))
                (set! count (+ count 1))
                (set! i (+ i 1))
                (set! col (+ col 1)))]
            [(= c 39)
              (let
                [end : i64 (ls-apostrophe-char-end buf i n)]
                (if (< end 0)
                  (begin
                    (set! acc (ls-fold acc ls-tag-quote 1 c))
                    (set! count (+ count 1))
                    (set! i (+ i 1))
                    (set! col (+ col 1)))
                  (begin
                    (set! acc (ls-fold acc ls-tag-char (- end i) c))
                    (set! count (+ count 1))
                    (set! col (+ col (- end i)))
                    (set! i end))))]
            [(= c 96)
              (begin
                (set! acc (ls-fold acc ls-tag-backtick 1 c))
                (set! count (+ count 1))
                (set! i (+ i 1))
                (set! col (+ col 1)))]
            [(= c 44)
              (begin
                (if (and (< (+ i 1) n) (= (ls-byte buf (+ i 1)) 64))
                  (begin
                    (set! acc (ls-fold acc ls-tag-comma-at 2 c))
                    (set! i (+ i 2))
                    (set! col (+ col 2)))
                  (begin
                    (set! acc (ls-fold acc ls-tag-comma 1 c))
                    (set! i (+ i 1))
                    (set! col (+ col 1))))
                (set! count (+ count 1)))]
            [(= c 34)
              (let
                [start : i64 (+ i 1)]
                [end : i64 (ls-scan-str-end buf start n)]
                [scan : i64 i]
                (begin
                  (set! acc (ls-fold acc ls-tag-str (- (+ end 1) i) c))
                  (set! count (+ count 1))
                  (while (< scan (+ end 1))
                    (begin
                      (if (= (ls-byte buf scan) 10)
                        (begin
                          (set! line (+ line 1))
                          (set! col 1))
                        (set! col (+ col 1)))
                      (set! scan (+ scan 1))))
                  (set! i (+ end 1))))]
            [(= c 59)
              (let
                [end : i64 (ls-scan-comment-end buf (+ i 1) n)]
                (begin
                  (set! col (+ col (- end i)))
                  (set! i end)))]
            [(or (ls-digit? c) (ls-negative-number-start? buf i n))
              (let
                [end : i64 (ls-scan-number-end buf i n)]
                [kind : i64
                  (if (ls-number-float? buf i n)
                    ls-tag-float
                    ls-tag-int)]
                (begin
                  (set! acc (ls-fold acc kind (- end i) c))
                  (set! count (+ count 1))
                  (set! col (+ col (- end i)))
                  (set! i end)))]
            [(= c 58)
              (let
                [end : i64 (ls-colon-token-end buf i n)]
                (begin
                  (set! acc (ls-fold acc ls-tag-sym (- end i) c))
                  (set! count (+ count 1))
                  (set! col (+ col (- end i)))
                  (set! i end)))]
            [(ls-symbol-char? c)
              (let
                [end : i64 (ls-scan-symbol-end buf i n)]
                (begin
                  (set! acc (ls-fold acc ls-tag-sym (- end i) c))
                  (set! count (+ count 1))
                  (set! col (+ col (- end i)))
                  (set! i end)))]
            [else
              (begin
                (set! acc (ls-fold acc ls-tag-unexpected 1 c))
                (set! count (+ count 1))
                (set! i (+ i 1))
                (set! col (+ col 1)))])))
      (+ (* acc 1000003) (+ (* line 31) (+ (* col 131) count))))))

;; Load the corpus once, then tokenize it `rounds` times. The corpus text is
;; copied into an `(Array u8)` so both implementations walk the same bytes
;; through the same kind of indexed byte access.
(define (ls-bench [path : String] [rounds : i64]) : i64
  (let
    [text : String (io.read-file path)]
    [buf : (Array u8)
      (byte_buf.bytes-to-array (byte_buf.str-as-bytes (& text)))]
    [n : i64 (array-length buf)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (while (< round rounds)
        (begin
          (set! acc (ls-tokenize buf n acc))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [path : String (io.arg 1)]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (ls-bench path rounds))
      0)))