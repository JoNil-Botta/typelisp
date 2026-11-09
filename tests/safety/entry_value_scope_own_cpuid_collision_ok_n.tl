;; Helper for entry_value_scope_own_cpuid_collision_ok (#9687).
(define (cpuid [a : i64] [b : i64]) : i64
  42)

(define (n-c) : i64
  (cpuid 0 0))