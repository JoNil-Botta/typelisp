;; #9687: a fresh empty name given to module-value-expr.
(import entry_value_scope_r4_fresh_name_value_expr_nz)

(define (helper) : i64
  33)

(define (main) : i64
  (entry_value_scope_r4_fresh_name_value_expr_nz.n-root))