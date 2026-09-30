(define (cap) : i64
  4096)

(define (big) : i64
  42)

(extern (foreign) : i64)

(defmacro (set-cap [value : Expr]) : Expr
  `(set! cap ,value))