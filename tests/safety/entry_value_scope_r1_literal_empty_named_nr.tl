;; Helper for entry_value_scope_r1_literal_empty_named (#9687).
(import stdlib.comptime)

(defmacro (call-root) : Expr
  (comptime.expr-call
    (comptime.module-value-expr "" "helper")
    (comptime.expr-list-empty)))

(define (n-root) : i64
  (call-root))