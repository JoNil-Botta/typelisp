;; csvstat - Summarize the columns of a CSV file.
;;
;; usage: csvstat [FILE|-]
;;
;; The first row names the columns. A column whose non-empty cells are all
;; integers is summarized with its count, sum, minimum and maximum; any other
;; column reports how many cells are non-empty. Output is tab-separated and in
;; column order. Malformed input is reported as `PATH:LINE:COL: error: ...`
;; with exit status 1; usage and read errors exit with status 2.
(import stdlib.io)
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.str_cat as str-cat)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import csv)

;: Running totals for one column.
(defstruct Column
  (name String)
  (numeric bool)
  (filled i64)
  (sum i64)
  (min i64)
  (max i64))

(import (vector.vector Column) as column-vec)

(define (usage) : i64
  (begin
    (io.print-error "usage: csvstat [FILE|-]\n")
    2))

;: Read standard input to its end.
(define (read-stdin-all) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [chunk : byte_buf.ByteBuf (io.read-stdin-bytes 65536)]
          (if (= (byte_buf.length (& chunk)) 0)
            (set! done true)
            (set! buf (byte_buf.append-bytes buf (byte_buf.as-bytes (& chunk)))))))
      (byte_buf.to-string buf))))

;: Report a malformed-input error. The message is formatted in a scratch
;: arena that ends once it is written.
(define (report-error [path : (& path str)] [error : (& error csv.CsvError)]) : i64
  (begin
    (with-arena
      message-scratch
      (let
        [path-text : String (string.copy path)]
        [line-text : String (string.int->string error.line)]
        [col-text : String (string.int->string error.col)]
        [message : String (string.copy (& error.message))]
        [location : String
          (str-cat.str-cat path-text ":" line-text ":" col-text)]
        [text : String (str-cat.str-cat location ": error: " message "\n")]
        (io.print-error (& text))))
    1))

(define (new-columns [table : (& table csv.Table)]) : column-vec.Vec
  (let
    [columns : column-vec.Vec (column-vec.new)]
    [i : i64 0]
    (begin
      (while (< i (csv.row-width table 0))
        (begin
          (column-vec.push! columns (Column (csv.field table 0 i) true 0 0 0 0))
          (set! i (+ i 1))))
      columns)))

;: Fold one cell into its column. The cell is read through a borrowed,
;: trimmed view of its text.
(define (add-cell [column : Column] [cell : String]) : Column
  (let
    [value : csv.ParsedInt (csv.parse-int (csv.trim (& cell)))]
    [n : i64 value.value]
    (cond
      [(= (string.string-length (& cell)) 0) column]
      [value.ok
        (Column
          column.name
          column.numeric
          (+ column.filled 1)
          (+ column.sum n)
          (if (or (= column.filled 0) (< n column.min))
            n
            column.min)
          (if (or (= column.filled 0) (> n column.max))
            n
            column.max))]
      [else (Column column.name false (+ column.filled 1) 0 0 0)])))

(define (column-line [column : (& column Column)]) : String
  (if column.numeric
    (str-cat.str-cat
      (string.copy (& column.name))
      "\tnumber\t"
      (string.int->string column.filled)
      "\t"
      (string.int->string column.sum)
      "\t"
      (string.int->string column.min)
      "\t"
      (string.int->string column.max)
      "\n")
    (str-cat.str-cat
      (string.copy (& column.name))
      "\ttext\t"
      (string.int->string column.filled)
      "\n")))

(define (summarize [path : String] [table : csv.Table]) : i64
  (if (= (csv.row-count (& table)) 0)
    (begin
      (io.print-error (str-cat.str-cat path ": error: no header row\n"))
      1)
    (let
      [width : i64 (csv.row-width (& table) 0)]
      [columns : column-vec.Vec (new-columns (& table))]
      [r : i64 1]
      [status : i64 0]
      (begin
        (while (and (= status 0) (< r (csv.row-count (& table))))
          (if (= (csv.row-width (& table) r) width)
            (let
              [c : i64 0]
              (begin
                (while (< c width)
                  (begin
                    (column-vec.set!
                      columns
                      c
                      (add-cell
                        (column-vec.get (& columns) c (Column "" false 0 0 0 0))
                        (csv.field (& table) r c)))
                    (set! c (+ c 1))))
                (set! r (+ r 1))))
            (let
              [error : csv.CsvError
                (csv.CsvError
                  (csv.row-line (& table) r)
                  1
                  (str-cat.str-cat
                    "expected "
                    (string.int->string width)
                    " fields, found "
                    (string.int->string (csv.row-width (& table) r))))]
              (set! status (report-error (& path) (& error))))))
        (if (= status 0)
          (let
            [c : i64 0]
            (begin
              (io.print-format
                "{}"
                (str-cat.str-cat
                  "rows\t"
                  (string.int->string (- (csv.row-count (& table)) 1))
                  "\n"))
              (while (< c width)
                (let
                  [column : Column
                    (column-vec.get (& columns) c (Column "" false 0 0 0 0))]
                  (begin
                    (io.print-format "{}" (column-line (& column)))
                    (set! c (+ c 1)))))
              0))
          status)))))

(define (run [path : String] [text : String]) : i64
  (match (csv.parse (& text))
    [(csv.ParseResult.Ok table) (summarize path table)]
    [(csv.ParseResult.Err error) (report-error (& path) (& error))]))

(define (main) : i64
  (if (not (= (io.arg-count) 2))
    (usage)
    (let
      [path : String (io.arg 1)]
      (if (string.eq (& path) "-")
        (run "<stdin>" (read-stdin-all))
        (match (io.try-read-file (& path))
          [(io.OkIoBytes contents) (run path (byte_buf.to-string contents))]
          [(io.ErrIoBytes error)
            (begin
              (io.print-error
                (str-cat.str-cat
                  "csvstat: cannot read "
                  path
                  ": "
                  (io.error-message error)
                  "\n"))
              2)])))))