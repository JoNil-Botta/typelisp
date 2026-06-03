(import "stdlib/io.tl")

(define (mix [x : i64] [y : i64]) : i64
  (% (+ (* x 33) (+ (* y 7) 11)) 1000000007))

(define (bench [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 5]
    (begin
      (while (< i n)
        (begin
          (set! acc (mix acc i))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    (begin
      (print (bench n))
      0)))
