;; Helper for entry_value_scope_j8_reflected_struct_ctor_ok (#9687).
(import stdlib.comptime)

(defmacro (rv [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) (type-nominal-name U))
    (comptime.expr-list-cons (comptime.expr-int 42) (comptime.expr-list-empty))))