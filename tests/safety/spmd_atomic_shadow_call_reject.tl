;: Only the stdlib extern atomic helpers can bypass varying-call rejection.
(define (atomic-i64-add!
  [out : (__tl_dyn-array i64)]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref out index) (+ (array-ref out index) value)))

(define (main
  [ix : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (atomic-i64-add! out (array-ref ix i) i)))