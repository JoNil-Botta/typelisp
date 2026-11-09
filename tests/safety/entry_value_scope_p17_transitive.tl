;; #9687: a function, two imports deep, seen from an imported module.
(import entry_value_scope_p17_transitive_nch2)

(define (helper) : i64
  17)

(define (main) : i64
  (entry_value_scope_p17_transitive_nch2.n-ch2))