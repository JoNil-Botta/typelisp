;; #9687: a module's own cpuid beside an entry cpuid, seen from an imported module.
(import entry_value_scope_own_cpuid_collision_ok_n)

(define (cpuid [a : i64] [b : i64]) : i64
  7)

(define (main) : i64
  (entry_value_scope_own_cpuid_collision_ok_n.n-c))