(import cpu_intrinsic_signature_provider.xgetbv)
(import cpu_intrinsic_signature_provider.cpuid)

(define (main) : i64
  (if (and (= (xgetbv true) 9) (= (cpuid 4) 17))
    42
    1))