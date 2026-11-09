;; #9687: the cpuid builtin beside a same-shaped entry define, seen from an imported module.
(import entry_value_scope_c8_cpuid_tuple_builtin_kept_n)

(define (cpuid [a : i64] [b : i64]) : (Tuple i32 i32 i32 i32)
  (tuple 7 7 7 7))

(define (main) : i64
  (entry_value_scope_c8_cpuid_tuple_builtin_kept_n.n-cpu3))