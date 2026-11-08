(import cpu_intrinsic_shadow_provider as foreign)

;; This used to pass checking but fail linkage on main for cpuid as well.
(define (main) : i64
  (unless (= (tuple-ref (foreign.cpuid 0 0) 0) 7) (return 2))
  (let
    [words : (Tuple i32 i32 i32 i32) (cpuid 0 0)]
    (if (=
      (bit-and (cast (tuple-ref words 0) : i64) 4294967295)
      (bit-and (cpuid-eax 0 0) 4294967295))
      42
      1)))
