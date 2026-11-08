;; Helper for entry_value_scope_c8_cpuid_tuple_builtin_kept (#9687).
(define (n-cpu3) : i64
  (if (= (cast (tuple-ref (cpuid 0 0) 0) : i64) 7)
    41
    42))