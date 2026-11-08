;; Helper for entry_value_scope_c2_cpuid_entry_i64_builtin_kept (#9687).
(define (n-cpu) : i64
  (if (>= (cast (tuple-ref (cpuid 0 0) 0) : i64) 0)
    42
    41))