(define (xgetbv [enabled : bool]) : i32
  (if enabled
    9
    8))

(define (cpuid [value : i64]) : i64
  (+ value 13))

(define (main) : i64
  (if (and (= (xgetbv true) 9) (= (cpuid 4) 17))
    42
    1))