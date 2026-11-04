(defmacro (choose) : Expr
  `(cond [true 0]))

(define (main) : i64
  (choose))