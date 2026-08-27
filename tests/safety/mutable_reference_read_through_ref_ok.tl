;: SPEC borrow contract: reads through the mutable reference value itself are
;: allowed while that reference is live.
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-length borrowed)]
    (begin
      (set! (array-ref borrowed 0) 41)
      n)))