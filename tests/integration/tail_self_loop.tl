(define (countdown [n : i64] [acc : i64]) : i64
  (if (= n 0)
      acc
      (countdown (- n 1) acc)))

(define (swapdown [a : i64] [b : i64] [n : i64]) : i64
  (if (= n 0)
      a
      (swapdown b a (- n 1))))

(define (main) : i64
  (if (= (countdown 100000 42) 42)
      (if (= (swapdown 1 2 100001) 2)
          42
          1)
      2))
