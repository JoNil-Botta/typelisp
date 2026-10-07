(define (sum-to [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (while (< i n)
      (set! i (+ i 1))
      (set! acc (+ acc i)))
    acc))

(define (main) : i64
  (sum-to 5))