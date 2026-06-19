(import "stdlib/io.tl")
(import "stdlib/string.tl")

(define (string-ops-round [text : String] [suffix : String] [span : i64]) : i64
  (let
    [n : i64 (string-length text)]
    [empty : String (substring text 0 0)]
    [short : String (substring text 0 4)]
    [tail : String (substring text (- n span) span)]
    [left : String (string-append empty short)]
    [right : String (string-append tail suffix)]
    [joined : String (string-append left right)]
    (+ (string-length joined) (string-length tail))))

(define (string-ops-repeat [text : String] [suffix : String] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    [span : i64 48]
    (begin
      (while (< i rounds)
        (begin
          (set! acc (+ acc (string-ops-round text suffix span)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [text : String (arg 1)]
    [suffix : String (arg 2)]
    [rounds : i64 (string->int (arg 3))]
    (begin
      (print (string-ops-repeat text suffix rounds))
      0)))