(define (sum-to [n : i64]) : i64
  (let (
    [i : i64 0]
    [acc : i64 0])
    (begin
      (while (< i n)
        (begin
          (set! i (+ i 1))
          (set! acc (+ acc i))))
      acc)))

(define (main) : i64
  (sum-to 5))