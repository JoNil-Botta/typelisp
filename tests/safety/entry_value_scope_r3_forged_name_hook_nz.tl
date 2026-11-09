;; Helper for entry_value_scope_r3_forged_name_hook (#9687).
(import stdlib.comptime)

(defmacro (call-root) : Expr
  (match (comptime.expr-var "")
    [(comptime.Var owner)
      (comptime.expr-call
        (comptime.module-hook owner "helper")
        (comptime.expr-list-empty))]
    [_ (comptime.expr-int 99)]))

(define (n-root) : i64
  (call-root))