;; Helper for entry_value_scope_r5_fresh_name_hook (#9687).
(import stdlib.comptime)

(defmacro (call-root) : Expr
  (comptime.expr-call
    (comptime.module-hook (comptime.syntax-name-fresh "") "helper")
    (comptime.expr-list-empty)))

(define (n-root) : i64
  (call-root))