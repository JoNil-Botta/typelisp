;; #9687: the cpuid builtin beside an entry define, seen from an imported module.
(import entry_value_scope_c2_cpuid_entry_i64_builtin_kept_n)

(define (cpuid [a : i64] [b : i64]) : i64
  7)

(define (main) : i64
  (entry_value_scope_c2_cpuid_entry_i64_builtin_kept_n.n-cpu))