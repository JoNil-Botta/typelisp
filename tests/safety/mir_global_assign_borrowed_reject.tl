;: Assigning a module value while a borrow of it is live is rejected.
(define names : (__tl_dyn-array i64)
  (__tl_make-array i64 1))

(define (keep [items : (& items (__tl_dyn-array i64))] [n : i64]) : i64
  (+ (array-length items) n))

(define (swap-out) : i64
  (keep
    (& names)
    (begin
      (set! names (__tl_make-array i64 3))
      0)))

(define (main) : i64
  0)