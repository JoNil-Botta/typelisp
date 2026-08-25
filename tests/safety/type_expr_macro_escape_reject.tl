(import stdlib.comptime)

(defmacro (emit-type [T : type]) : Expr
  (comptime.type-expr T))

(define (main) : i64
  (emit-type i64))