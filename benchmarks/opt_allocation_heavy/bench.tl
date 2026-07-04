(import stdlib.io)
(import stdlib.string)

(define (bench [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (let
          [text : String (string.int->string (+ (* i 17) 5))]
          (begin
            (set! acc (+ acc (string.string-length text)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    (begin
      (io.print (bench n))
      0)))