(import cpu_query_intrinsics_dep as cpu)
(import cpu_query_intrinsics_dep.imported-query as cpuid-eax)

(define (xgetbv [_index : i64]) : i64
  9)

(define (main) : i64
  (if (and (cpu.hardware-queries-ok?) (= (cpuid-eax) 9))
    (let
      [xgetbv
        (lambda () : i64
          9)]
      (if (= (xgetbv) 9)
        (user-query)
        1))
    2))

(define (user-query) : i64
  (xgetbv 0))