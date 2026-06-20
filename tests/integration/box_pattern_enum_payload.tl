(defenum Expr
  (Lit i64)
  (Add (Box Expr) (Box Expr)))

(define (eval [expr : Expr]) : i64
  (match expr
    [(Lit value) value]
    [(Add (box left) (box right)) (+ (eval left) (eval right))]))

(define (main) : i64
  (eval (Add (box (Lit 19)) (box (Lit 23)))))