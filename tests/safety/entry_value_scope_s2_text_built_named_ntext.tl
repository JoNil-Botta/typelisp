;; Helper for entry_value_scope_s2_text_built_named (#9687).
(import stdlib.comptime)

(defmacro (call-text) : Expr
  (comptime.expr-call (comptime.expr-var "helper") (comptime.expr-list-empty)))

(define (n-text) : i64
  (call-text))