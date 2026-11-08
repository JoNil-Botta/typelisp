;; #9687: assignment to a global, seen from an imported module.
(import entry_value_scope_p05_set_nset)

(define counter : i64
  0)

(define (main) : i64
  (entry_value_scope_p05_set_nset.n-set)
  counter)