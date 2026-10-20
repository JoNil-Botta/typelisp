(module b)

(import a)

(defmacro (make-a [_declaration : Expr]) : Decls
  `(defmacro (make-b [declaration : Expr]) : Decls
    declaration))

(define (value) : i64
  (a.value))