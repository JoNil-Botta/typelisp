(import stdlib.comptime as ct)

;; A non-unit first form is discarded, then the second form must run at CTFE.
(defmacro (reject) : Expr
  (ct.expr-int 11)
  (ct.comptime-error "second macro body effect")
  (ct.expr-int 42))