(import "stdlib/io.tl")

(define (sum-tail [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (sum-tail (- n 1) (% (+ acc (* n 3)) 1000000007))))

(define (main) : i64
  (let
    [n : i64 (string->int (arg 1))]
    (begin
      (print (sum-tail n 0))
      0)))