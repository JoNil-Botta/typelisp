(import stdlib.comptime as ct)

;; The first form must issue its diagnostic before either later form runs.
(defmacro (reject) : Expr
  (ct.comptime-error "first macro body effect")
  (ct.comptime-error "second macro body effect")
  (ct.expr-int 42))

(define (main) : i64
  (reject))