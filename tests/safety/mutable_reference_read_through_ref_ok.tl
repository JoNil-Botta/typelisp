;: SPEC borrow contract: reads through the mutable reference value itself are
;: allowed while that reference is live.
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array-length borrowed)]
    (begin
      (array-set! borrowed 0 41)
      n)))