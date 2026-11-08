(define (xcr-tail) : i64
  (xgetbv 0))

(define (xcr-expression) : i64
  (+ 0 (xgetbv 0)))

(define (leaf-tail) : (Tuple i32 i32 i32 i32)
  (cpuid 0 0))

(define (leaf-expression) : i64
  (bit-and (cast (tuple-ref (cpuid 0 0) 0) : i64) 4294967295))