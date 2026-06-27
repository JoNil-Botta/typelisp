;: SPEC borrow contract: reads through the mutable reference value itself are
;: allowed while that reference is live.
(import stdlib.array)

(define (main) : i64
  (let
    [items : (Array i64) (array.make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array.array-length borrowed)]
    (begin
      (array.array-set! borrowed 0 41)
      n)))