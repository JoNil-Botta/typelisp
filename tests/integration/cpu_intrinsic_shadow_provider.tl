(define (xgetbv [value : i64]) : i64
  (+ value 9))

(define (cpuid [_leaf : i64] [_subleaf : i64]) : (Tuple i32 i32 i32 i32)
  (tuple 7 7 7 7))