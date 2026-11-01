;: A move-only operand passed through a function value is consumed.
(define (keep [items : (__tl_dyn-array i64)]) : i64
  (array-length items))

(define (twice
  [f : (-> (__tl_dyn-array i64) i64)]
  [items : (__tl_dyn-array i64)]) : i64
  (+ (f items) (f items)))

(define (main) : i64
  (twice keep (__tl_make-array i64 2)))