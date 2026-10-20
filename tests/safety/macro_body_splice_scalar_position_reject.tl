(defmacro (bad-branch [body : Expr ...]) : Expr
  `(if true
    ,@body
    0))

(define (main) : i64
  (bad-branch 20 42))