(defmacro (fail) : Expr
  (comptime-error "reject this input"))

(define (main) : i64
  (fail))