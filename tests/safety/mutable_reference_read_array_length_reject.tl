;: SPEC borrow contract: owner reads conflict with a live mutable borrow.
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-length items)]
    (begin
      (set! (array-ref borrowed 0) 41)
      (+ n 1))))