;: SPEC borrow contract: owner reads conflict with a live mutable borrow.
(import stdlib.array)

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-length items)]
    (begin
      (array-set! borrowed 0 41)
      (+ n 1))))