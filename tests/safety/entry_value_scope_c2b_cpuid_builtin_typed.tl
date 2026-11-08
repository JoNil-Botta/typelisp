;; #9687: the cpuid builtin type beside an entry define, seen from an imported module.
(import entry_value_scope_c2b_cpuid_builtin_typed_n)

(define (cpuid [a : i64] [b : i64]) : i64
  7)

(define (main) : i64
  (entry_value_scope_c2b_cpuid_builtin_typed_n.n-cpu2))