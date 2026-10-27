(define (by-value [x : i64]) : i64
  (+ x 1))

(define (by-call [x : i64]) : i64
  (+ x 2))

(defdispatch value-auto (scalar by-value) (avx2 by-value) (avx512 by-value))

(defdispatch call-auto (scalar by-call) (avx2 by-call) (avx512 by-call))

(define callback : (-> i64 i64)
  by-value)