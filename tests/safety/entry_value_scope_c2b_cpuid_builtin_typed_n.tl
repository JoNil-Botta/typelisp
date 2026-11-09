;; Helper for entry_value_scope_c2b_cpuid_builtin_typed (#9687).
(define (n-cpu2) : i64
  (cpuid 0 0))