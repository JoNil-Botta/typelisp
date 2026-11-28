(define (report-message)
  (:cold)
  unit)

(define (cold-code)
  (:cold) : i64
  20)

(defmacro (emit [name : Expr]) : Decls
  `(define (,name)
    (:cold) : i64
    20))

(emit generated-code)

(define (add-offset [comptime offset : i64] [value : i64])
  (:cold) : i64
  (+ offset value))

(define (main) : i64
  (report-message)
  (add-offset 2 (+ (cold-code) (generated-code))))