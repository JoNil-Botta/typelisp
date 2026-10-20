(defmacro (bad-body [body : Expr ...]) : Expr
  (let
    []
    ,@body))

(define (main) : i64
  (bad-body 42))