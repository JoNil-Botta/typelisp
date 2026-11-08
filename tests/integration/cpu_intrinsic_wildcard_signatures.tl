(import cpu_intrinsic_signature_provider.*)

(define (main) : i64
  (if (and (= (xgetbv false) 8) (= (cpuid 5) 18))
    42
    1))