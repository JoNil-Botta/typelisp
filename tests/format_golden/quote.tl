(define (mk [e : Expr]) : Expr `(if ,e true false)) (define (body [xs : ExprList]) : Expr `(begin ,@xs))
