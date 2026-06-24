; #2743: opt2 can reclaim loop-body allocations that provably do not escape.
(define (scratch-sum [n : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (let
          [cell : (Box i64) (box i)]
          (begin
            (set! acc (+ acc (box-get cell)))
            (set! i (+ i 1)))))
      acc)))

(define (main) : i64
  (if (= (scratch-sum 1000) 499500)
    42
    1))