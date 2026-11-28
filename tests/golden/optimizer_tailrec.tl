(define (sum-down [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (sum-down (- n 1) (+ acc n))))

(define (main) : i64
  (sum-down 9 0))