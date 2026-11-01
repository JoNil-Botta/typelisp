;: A mutable borrow of a box's contents excludes other access to the box.
(define (run [items : (Box (__tl_dyn-array i64))]) : i64
  (let
    [contents : (&mut items (__tl_dyn-array i64)) (&mut (deref items))]
    (begin
      (set! (deref items) (__tl_make-array i64 0))
      (__tl_array-push! contents 1)
      0)))

(define (main) : i64
  0)