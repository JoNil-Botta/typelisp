(import stdlib.io)
(import stdlib.string)

(define (sum-tail [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (sum-tail (- n 1) (% (+ acc (* n 3)) 1000000007))))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    (begin
      (io.print (sum-tail n 0))
      0)))