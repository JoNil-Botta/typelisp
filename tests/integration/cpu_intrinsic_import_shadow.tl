(import cpu_intrinsic_shadow_provider as cpu)
(import cpu_intrinsic_shadow_provider.xgetbv)
(import cpu_intrinsic_shadow_provider.cpuid)

(define (main) : i64
  (if (and
    (= (xgetbv 0) 9)
    (= (cpu.xgetbv 1) 10)
    (= (tuple-ref (cpuid 0 0) 0) 7)
    (= (tuple-ref (cpu.cpuid 0 0) 0) 7))
    42
    1))