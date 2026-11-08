;; Helper for entry_value_scope_p12_macro_named (#9687).
(defmacro (call-helper) : Expr
  `(helper))

(define (n-mac) : i64
  (call-helper))