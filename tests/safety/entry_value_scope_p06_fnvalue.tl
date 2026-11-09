;; #9687: a function used as a value, seen from an imported module.
(import entry_value_scope_p06_fnvalue_nfv)

(define (helper) : i64
  6)

(define (main) : i64
  (entry_value_scope_p06_fnvalue_nfv.n-fv))