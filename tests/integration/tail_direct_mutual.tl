; Direct non-self tail calls jump to the next function frame in-place (#2361).
(define (even-tail [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (odd-tail (- n 1) acc)))

(define (odd-tail [n : i64] [acc : i64]) : i64
  (if (= n 0)
    acc
    (even-tail (- n 1) acc)))

(define (main) : i64
  (even-tail 100000 42))