;; #9687: module-value-expr with a literal "" owner, seen from an imported module.
(import entry_value_scope_r1_literal_empty_named_nr)

(define (helper) : i64
  33)

(define (main) : i64
  (entry_value_scope_r1_literal_empty_named_nr.n-root))