;; source_text_core.tl - The reader's lexical rules and position arithmetic
;; that the tooling scanners share over raw, possibly half-typed TypeLisp text.
;;
;; The LSP (cursor context, folding, links, declaration scans), the lint driver
;; (form counting), lint rules (span to offset), the REPL (input completeness)
;; and the doc extractor walk source text byte by byte without a parse. They
;; agree on where whitespace, a line comment, a string literal and a character
;; literal end, and on byte offset <-> (line, column) conversion; this module
;; is that one definition. Every skip takes an explicit scan limit `n` because
;; scanners also walk sub-ranges of a buffer.
;;
;; `starts-with?`, `ends-with?` and the `line-end` / `next-line-start` walk
;; belong in stdlib.string, but a new stdlib.string function is emitted into
;; every program that keeps the whole module, which changes generated code;
;; they live here until a codegen-changing change moves them.
(import stdlib.io)
(import stdlib.string)

(define (source-text-space? [c : char]) : bool
  (or (= c ' ') (= c '\t') (= c '\n') (= c '\r')))

;; First non-whitespace offset at or after `i`, or `n`.
(define (source-text-skip-space [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (source-text-space? (string.string-ref text j)))
        (set! j (+ j 1)))
      j)))

;; Offset just past the `\n` that ends the line containing `i`, or `n`.
(define (source-text-skip-line [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [j : i64 i]
    (begin
      (while (and (< j n) (not (= (string.string-ref text j) '\n')))
        (set! j (+ j 1)))
      (if (< j n)
        (+ j 1)
        j))))

;; Offset just past the string literal whose opening quote is at `i`. An
;; escape skips two bytes, so an unterminated literal ending in `\` stops at
;; `n + 1`.
(define (source-text-skip-string [text : (& text str)] [i : i64] [n : i64]) : i64
  (let
    [j : i64 (+ i 1)]
    [done : bool false]
    (begin
      (while (and (< j n) (not done))
        (let
          [c : char (string.string-ref text j)]
          (cond
            [(= c '\\') (set! j (+ j 2))]
            [(= c '"')
              (begin
                (set! done true)
                (set! j (+ j 1)))]
            [else (set! j (+ j 1))])))
      j)))

(define (source-text-char-escape? [c : char]) : bool
  (or (= c 'n') (= c 't') (= c 'r') (= c '0') (= c '\\') (= c '\'')))

;; Offset just past the character literal whose apostrophe is at `i` (`'a'`,
;; `'\n'`). An apostrophe that opens no complete character literal is a quote,
;; one byte long.
(define (source-text-skip-char-literal
  [text : (& text str)]
  [i : i64]
  [n : i64]) : i64
  (if (< (+ i 1) n)
    (let
      [payload : char (string.string-ref text (+ i 1))]
      (cond
        [(= payload '\\')
          (if (and
            (< (+ i 3) n)
            (source-text-char-escape? (string.string-ref text (+ i 2)))
            (= (string.string-ref text (+ i 3)) '\''))
            (+ i 4)
            (+ i 1))]
        [(or (= payload '\'') (= payload '\n') (= payload '\r')) (+ i 1)]
        [else
          (if (and (< (+ i 2) n) (= (string.string-ref text (+ i 2)) '\''))
            (+ i 3)
            (+ i 1))]))
    (+ i 1)))

;; A UTF-8 continuation byte adds no UTF-16 code unit.
(define (source-text-utf8-continuation-byte? [c : char]) : bool
  (= (bit-and (cast c : i64) 192) 128))

;; Column units one UTF-8 byte contributes: 1 when counting bytes; in UTF-16, a
;; four-byte lead is a surrogate pair and continuation bytes add nothing.
(define (source-text-column-units [c : char] [utf16 : bool]) : i64
  (if (not utf16)
    1
    (let
      [b : i64 (cast c : i64)]
      (cond [(source-text-utf8-continuation-byte? c) 0] [(>= b 240) 2] [else 1]))))

;; Byte offset of the 0-based (`line0`, byte column `col0`), clamped to the
;; line and to the text.
(define (source-text-offset-at-byte-position
  [text : (& text str)]
  [line0 : i64]
  [col0 : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [line : i64 0]
    [col : i64 0]
    (begin
      (while (and (< i n) (< line line0))
        (begin
          (when (= (string.string-ref text i) '\n') (set! line (+ line 1)))
          (set! i (+ i 1))))
      (while (and
        (< i n)
        (< col col0)
        (not (= (string.string-ref text i) '\n')))
        (begin
          (set! i (+ i 1))
          (set! col (+ col 1))))
      i)))

;; 1-based line and column of byte offset `off` (clamped to the text), the
;; column counted in bytes or in UTF-16 code units.
(defstruct SourceTextLineCol
  (line i64)
  (col i64))

(define (source-text-line-col-at-offset
  [text : (& text str)]
  [off : i64]
  [utf16 : bool]) : SourceTextLineCol
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    (begin
      (while (and (< i n) (< i off))
        (begin
          (if (= (string.string-ref text i) '\n')
            (begin
              (set! line (+ line 1))
              (set! col 1))
            (set!
              col
              (+
                col
                (source-text-column-units (string.string-ref text i) utf16))))
          (set! i (+ i 1))))
      (SourceTextLineCol line col))))

;; Line-start table of one text: `starts[k]` is the byte offset of 1-based line
;; `k + 1`. Built once per text, it turns span-to-offset conversion into an
;; index and offset-to-line into a binary search.
(define (source-text-line-starts [text : (& text str)]) : (__tl_dyn-array i64)
  (let
    [n : i64 (string.string-length text)]
    [index : i64 0]
    [line-count : i64 1]
    (begin
      (while (< index n)
        (begin
          (when
            (= (string.string-ref text index) '\n')
            (set! line-count (+ line-count 1)))
          (set! index (+ index 1))))
      (let
        [starts : (__tl_dyn-array i64) (__tl_make-array i64 line-count)]
        [line-index : i64 1]
        (begin
          (set! index 0)
          (while (< index n)
            (begin
              (when
                (= (string.string-ref text index) '\n')
                (begin
                  (set! (array-ref starts line-index) (+ index 1))
                  (set! line-index (+ line-index 1))))
              (set! index (+ index 1))))
          starts)))))

;; Byte offset where 1-based `line` starts, or -1 when the text has no such line.
(define (source-text-line-start
  [starts : (& starts (__tl_dyn-array i64))]
  [line : i64]) : i64
  (if (or (<= line 0) (> line (array-length starts)))
    -1
    (array-ref starts (- line 1))))

;; 0-based index of the line containing byte offset `offset`.
(define (source-text-line-index
  [starts : (& starts (__tl_dyn-array i64))]
  [offset : i64]) : i64
  (let
    [low : i64 0]
    [high : i64 (array-length starts)]
    (begin
      (while (< low high)
        (let
          [mid : i64 (/ (+ low high) 2)]
          (if (<= (array-ref starts mid) offset)
            (set! low (+ mid 1))
            (set! high mid))))
      (- low 1))))

;; True if `text` begins with `prefix`.
(define (starts-with? [text : (& text str)] [prefix : (& prefix str)]) : bool
  (string.is-string-prefix-at text prefix 0))

;; True if `text` ends with `suffix`.
(define (ends-with? [text : (& text str)] [suffix : (& suffix str)]) : bool
  (string.is-string-prefix-at
    text
    suffix
    (- (string.string-length text) (string.string-length suffix))))

;; End of the line starting at `start`: the index of the next `\n` or `\r`, or
;; the length of `text` when the last line is unterminated.
(define (line-end [text : (& text str)] [start : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [i : i64 start]
    (begin
      (while (and
        (< i n)
        (not (= (string.string-ref text i) '\n'))
        (not (= (string.string-ref text i) '\r')))
        (set! i (+ i 1)))
      i)))

;; Start of the line after the one `line-end` ended at `end`, consuming one
;; `\n`, `\r` or `\r\n` break. At the end of `text` it returns `end`.
(define (next-line-start [text : (& text str)] [end : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    (cond
      [(>= end n) end]
      [(and
          (= (string.string-ref text end) '\r')
          (< (+ end 1) n)
          (= (string.string-ref text (+ end 1)) '\n'))
        (+ end 2)]
      [else (+ end 1)])))

(test
  source-text-prefix-suffix-and-line-helpers
  (unless
    (and
      (starts-with? "typelisp" "type")
      (starts-with? "typelisp" "")
      (not (starts-with? "type" "typelisp"))
      (ends-with? "stdlib/io.tl" ".tl")
      (ends-with? "io.tl" "")
      (not (ends-with? ".tl" "io.tl"))
      (not (ends-with? "io.tl" ".tlx"))
      (= (line-end "ab\r\ncd" 0) 2)
      (= (line-end "ab\ncd" 3) 5)
      (= (next-line-start "ab\r\ncd" 2) 4)
      (= (next-line-start "ab\rcd" 2) 3)
      (= (next-line-start "ab\n" 2) 3)
      (= (next-line-start "ab" 2) 2))
    (io.panic "source-text prefix/suffix/line helpers changed")))