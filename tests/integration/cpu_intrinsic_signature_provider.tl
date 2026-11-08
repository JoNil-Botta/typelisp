(define (xgetbv [enabled : bool]) : i32
  (if enabled
    9
    8))

(define (cpuid [value : i64]) : i64
  (+ value 13))