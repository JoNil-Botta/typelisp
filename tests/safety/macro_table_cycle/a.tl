(module a)

(import b)

(b.make-a
  `(defmacro (make-b [declaration : Expr]) : Decls
    declaration))

(define (value) : i64
  42)