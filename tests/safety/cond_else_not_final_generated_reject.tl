(defmacro (choose) : Expr
  `(cond [else 0] [true 1]))

(define (main) : i64
  (choose))