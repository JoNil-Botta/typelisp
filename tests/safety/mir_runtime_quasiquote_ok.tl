;; A runtime quote is a fresh syntax value and a quasiquote reads each
;; unquoted `Expr` and spliced `ExprList` into one (#8449 M5).
(define (wrap [e : Expr]) : Expr
  `(if ,e
    true
    false))

(define (body [xs : ExprList]) : Expr
  `(begin
    ,@xs))

(define (literal) : Expr
  (quote x))

(define (main) : i64
  42)