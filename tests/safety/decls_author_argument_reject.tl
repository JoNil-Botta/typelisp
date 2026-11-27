(defmacro (emit [_value : i64]) : Decls
  `(define answer : i64
    42))

(defmacro (outer) : Decls
  `(emit (comptime-error "reviewer")))

(define (main) : i64
  0)

(outer)