(import stdlib.io)
(import stdlib.string)

(define (string-ops-round [text : String] [suffix : String] [span : i64]) : i64
  (let
    [n : i64 (string.string-length text)]
    [empty : String (string.substring text 0 0)]
    [short : String (string.substring text 0 4)]
    [tail : String (string.substring text (- n span) span)]
    [left : String (string.append empty short)]
    [right : String (string.append tail suffix)]
    [joined : String (string.append left right)]
    (+ (string.string-length joined) (string.string-length tail))))

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
    [text : String (io.arg 1)]
    [suffix : String (io.arg 2)]
    [rounds : i64 (string.>int (io.arg 3))]
    (begin
      (io.print (string-ops-repeat text suffix rounds))
      0)))