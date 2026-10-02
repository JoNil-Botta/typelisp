;: An unquote inside a quasiquoted `try` is checked like any other template
;: operand, even when the macro is never expanded.
(defmacro (try-number [place : Expr]) : Expr
  `(try ,(+ 1 2)))

(define (main) : i64
  0)