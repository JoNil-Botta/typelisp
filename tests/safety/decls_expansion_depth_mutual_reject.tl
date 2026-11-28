(defmacro (first) : Decls
  `(second))

(defmacro (second) : Decls
  `(first))

(first)

(define (main) : i64
  0)