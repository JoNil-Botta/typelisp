(define (read-local [xgetbv : (-> i64 i64)]) : i64
  (xgetbv 0))

(define (read-cpuid [cpuid : (-> i64 i64 i64)]) : i64
  (cpuid 0 0))

(define (main) : i64
  (let
    [xgetbv : (-> i64 i64)
      (lambda ([_index : i64]) : i64
        9)]
    [cpuid : (-> i64 i64 i64)
      (lambda ([_leaf : i64] [_subleaf : i64]) : i64
        7)]
    (if (and
      (= (xgetbv 0) 9)
      (= (read-local xgetbv) 9)
      (= (cpuid 0 0) 7)
      (= (read-cpuid cpuid) 7))
      42
      1)))