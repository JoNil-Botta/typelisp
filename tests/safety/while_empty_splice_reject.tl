(defmacro (loop-forms [body : Expr ...]) : Expr
  `(while false
    ,@body))

(define (main) : i64
  (loop-forms)
  0)