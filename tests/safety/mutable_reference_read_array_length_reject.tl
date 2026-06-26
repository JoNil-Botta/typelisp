;: SPEC borrow contract: owner reads conflict with a live mutable borrow.
(import stdlib.array)

(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array.array-length items)]
    (begin
      (array.array-set! borrowed 0 41)
      (+ n 1))))