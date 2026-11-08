(import stdlib.cpu as cpu)
(import cpu_intrinsic_shadow_provider as foreign)

;; The alias-only import does not replace the entry's prebound value.
(define (main) : i64
  (if (cpu.osxsave?)
    (if (= (xgetbv 0) (cpu.xcr0))
      42
      1)
    42))