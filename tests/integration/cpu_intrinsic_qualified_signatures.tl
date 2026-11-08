(import cpu_intrinsic_signature_provider as cpu)

(define (main) : i64
  (if (and (= (cpu.xgetbv true) 9) (= (cpu.cpuid 4) 17))
    42
    1))