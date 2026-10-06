(defmacro (loop-forms [body : Expr ...]) : Expr
  `(while false
    ,@body))

(define (value) : i64
  1)

(define (main) : i64
  (loop-forms unit (value) unit)
  0)