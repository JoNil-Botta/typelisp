(module b)

(import a)

(a.make-b
  `(defmacro (make-a [declaration : Expr]) : Decls
    declaration))