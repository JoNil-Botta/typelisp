;; Helper for entry_value_scope_r4_fresh_name_value_expr (#9687).
(import stdlib.comptime)

(defmacro (call-root) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (comptime.syntax-name-fresh "") "helper")
    (comptime.expr-list-empty)))

(define (n-root) : i64
  (call-root))