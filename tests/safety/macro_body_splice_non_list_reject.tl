(defmacro (bad-body [value : Expr]) : Expr
  `(let
    []
    ,@value))

(define (main) : i64
  (bad-body 42))