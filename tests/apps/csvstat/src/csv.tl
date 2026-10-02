;; csv.tl - A small RFC 4180-style CSV reader for csvstat.
;;
;; Fields are separated by commas and rows by LF or CRLF. A field that starts
;; with a double quote may contain commas, line breaks and doubled quotes. The
;; reader borrows the input text and returns owned rows, or the first error with
;; its 1-based line and column. A table stores every field in one vector, with
;; the index of each row's first field and the line the row starts on.
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)
(cfg test (import stdlib.test))

;: Parsed rows: all fields in order, each row's first field index and the line
;: it starts on.
(defstruct Table
  (fields svec.Vec)
  (starts ivec.Vec)
  (lines ivec.Vec))

;: The first malformed spot in the input.
(defstruct CsvError
  (line i64)
  (col i64)
  (message String))

(defenum ParseResult
  (Ok Table)
  (Err CsvError))

;: The result of reading a cell as an integer.
(defstruct ParsedInt
  (ok bool)
  (value i64))

(define (quote-char) : char
  '"')

;: Parse all rows of `text`. Blank lines are skipped; the last row needs no
;: trailing line break.
(define (parse [text : (& text str)]) : ParseResult
  (let
    [n : i64 (string.string-length text)]
    [i : i64 0]
    [line : i64 1]
    [col : i64 1]
    [fields : svec.Vec (svec.new)]
    [starts : ivec.Vec (ivec.new)]
    [lines : ivec.Vec (ivec.new)]
    [pending-start : i64 0]
    [field : text_buf.TextBuf (text_buf.empty)]
    [pending-line : i64 1]
    [in-quotes : bool false]
    [closed-quote : bool false]
    [quote-line : i64 0]
    [quote-col : i64 0]
    [failed : bool false]
    [error : CsvError (CsvError 0 0 "")]
    (begin
      (while (and (not failed) (< i n))
        (let
          [c : char (string.string-ref text i)]
          (cond
            [in-quotes
              (cond
                [(= c (quote-char))
                  (if (and
                    (< (+ i 1) n)
                    (= (string.string-ref text (+ i 1)) (quote-char)))
                    (begin
                      (set! field (text_buf.append-char field c))
                      (set! i (+ i 2))
                      (set! col (+ col 2)))
                    (begin
                      (set! in-quotes false)
                      (set! closed-quote true)
                      (set! i (+ i 1))
                      (set! col (+ col 1))))]
                [(= c '\n')
                  (begin
                    (set! field (text_buf.append-char field c))
                    (set! i (+ i 1))
                    (set! line (+ line 1))
                    (set! col 1))]
                [else
                  (begin
                    (set! field (text_buf.append-char field c))
                    (set! i (+ i 1))
                    (set! col (+ col 1)))])]
            [(= c ',')
              (begin
                (svec.push!
                  fields
                  (text_buf.render (replace! field (text_buf.empty))))
                (set! closed-quote false)
                (set! i (+ i 1))
                (set! col (+ col 1)))]
            [(or
                (= c '\n')
                (and
                  (= c '\r')
                  (< (+ i 1) n)
                  (= (string.string-ref text (+ i 1)) '\n')))
              (begin
                (if (and
                  (= (svec.len (& fields)) pending-start)
                  (text_buf.empty? (& field))
                  (not closed-quote))
                  unit
                  (begin
                    (svec.push!
                      fields
                      (text_buf.render (replace! field (text_buf.empty))))
                    (ivec.push! starts pending-start)
                    (ivec.push! lines pending-line)
                    (set! pending-start (svec.len (& fields)))))
                (set! closed-quote false)
                (set!
                  i
                  (+
                    i
                    (if (= c '\r')
                      2
                      1)))
                (set! line (+ line 1))
                (set! col 1)
                (set! pending-line line))]
            [(= c (quote-char))
              (if (and (text_buf.empty? (& field)) (not closed-quote))
                (begin
                  (set! in-quotes true)
                  (set! quote-line line)
                  (set! quote-col col)
                  (set! i (+ i 1))
                  (set! col (+ col 1)))
                (begin
                  (set! failed true)
                  (set!
                    error
                    (CsvError line col "quote inside an unquoted field"))))]
            [closed-quote
              (begin
                (set! failed true)
                (set!
                  error
                  (CsvError
                    line
                    col
                    "unexpected character after a closing quote")))]
            [else
              (begin
                (set! field (text_buf.append-char field c))
                (set! i (+ i 1))
                (set! col (+ col 1)))])))
      (cond
        [failed (Err error)]
        [in-quotes
          (Err (CsvError quote-line quote-col "unterminated quoted field"))]
        [else
          (begin
            (if (and
              (= (svec.len (& fields)) pending-start)
              (text_buf.empty? (& field))
              (not closed-quote))
              unit
              (begin
                (svec.push!
                  fields
                  (text_buf.render (replace! field (text_buf.empty))))
                (ivec.push! starts pending-start)
                (ivec.push! lines pending-line)))
            (Ok (Table fields starts lines)))]))))

;: The number of rows in `table`.
(define (row-count [table : (& table Table)]) : i64
  (ivec.len (& table.starts)))

;: The line row `row` starts on.
(define (row-line [table : (& table Table)] [row : i64]) : i64
  (ivec.get (& table.lines) row 0))

(define (row-start [table : (& table Table)] [row : i64]) : i64
  (ivec.get (& table.starts) row 0))

;: The number of fields in row `row`.
(define (row-width [table : (& table Table)] [row : i64]) : i64
  (-
    (if (< (+ row 1) (row-count table))
      (row-start table (+ row 1))
      (svec.len (& table.fields)))
    (row-start table row)))

;: Field `col` of row `row`.
(define (field [table : (& table Table)] [row : i64] [col : i64]) : String
  (svec.get (& table.fields) (+ (row-start table row) col) ""))

(define (digit? [c : char]) : bool
  (and (>= c '0') (<= c '9')))

;: A view of `text` without its leading and trailing spaces; nothing is copied.
(define (trim [text : (& text str)]) : (& text str)
  (let
    [start : i64 0]
    [end : i64 (string.string-length text)]
    (begin
      (while (and (< start end) (= (string.string-ref text start) ' '))
        (set! start (+ start 1)))
      (while (and (> end start) (= (string.string-ref text (- end 1)) ' '))
        (set! end (- end 1)))
      (string.substring-view text start (- end start)))))

;: Read `text` as a decimal integer with an optional leading minus sign.
;:
;: ```typelisp
;: (import csv)
;:
;: (define (main) : i64
;:   (let
;:     [parsed : csv.ParsedInt (csv.parse-int "-42")]
;:     (if (and parsed.ok (= parsed.value -42))
;:       0
;:       1)))
;: ```
(define (parse-int [text : (& text str)]) : ParsedInt
  (let
    [n : i64 (string.string-length text)]
    [start : i64
      (if (and (> n 0) (= (string.string-ref text 0) '-'))
        1
        0)]
    [i : i64 start]
    [value : i64 0]
    [ok : bool (> n start)]
    (begin
      (while (and ok (< i n))
        (let
          [c : char (string.string-ref text i)]
          (if (digit? c)
            (begin
              (set! value (+ (* value 10) (- (cast c : i64) (cast '0' : i64))))
              (set! i (+ i 1)))
            (set! ok false))))
      (ParsedInt
        ok
        (if (= start 1)
          (- 0 value)
          value)))))

(test
  parse-quoted-fields
  (match (parse "a,\"b,c\",\"say \"\"hi\"\"\"\n")
    [(Ok table)
      (begin
        (test.assert-i64-eq (row-count (& table)) 1 "one row")
        (test.assert-i64-eq (row-width (& table) 0) 3 "three fields")
        (test.assert-string-eq
          (field (& table) 0 2)
          "say \"hi\""
          "doubled quotes unescape"))]
    [(Err _) (test.assert-true false "parse should succeed")]))

(test
  parse-crlf-and-blank-lines
  (match (parse "x,y\r\n\r\n1,2\r\n")
    [(Ok table)
      (begin
        (test.assert-i64-eq (row-count (& table)) 2 "blank line skipped")
        (test.assert-i64-eq (row-line (& table) 1) 3 "second row line")
        (test.assert-string-eq (field (& table) 1 1) "2" "no carriage return"))]
    [(Err _) (test.assert-true false "parse should succeed")]))

(test
  parse-unterminated-quote
  (match (parse "x,y\n1,\"open\n")
    [(Ok _) (test.assert-true false "parse should fail")]
    [(Err error)
      (begin
        (test.assert-i64-eq error.line 2 "error line")
        (test.assert-i64-eq error.col 3 "error column"))]))

(test
  parse-int-forms
  (begin
    (let
      [negative : ParsedInt (parse-int "-42")]
      (begin
        (test.assert-true negative.ok "-42 is an integer")
        (test.assert-i64-eq negative.value -42 "negative")))
    (test.assert-false (parse-int "4x").ok "4x is not an integer")
    (test.assert-false (parse-int "-").ok "- is not an integer")
    (test.assert-false (parse-int "").ok "empty is not an integer")
    (test.assert-true (parse-int (trim "  7 ")).ok "trimmed cell")))