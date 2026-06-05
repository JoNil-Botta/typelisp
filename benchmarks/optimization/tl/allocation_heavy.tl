(import "stdlib/io.tl")

(define (bench [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (let
          [text : String (int->string (+ (* i 17) 5))]
          (begin
            (set! acc (+ acc (string-length text)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    (begin
      (print (bench n))
      0)))