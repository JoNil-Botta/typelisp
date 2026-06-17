;: SPEC borrow contract: element reads conflict with an overlapping live
;: mutable owner borrow.
(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    [borrowed : (&mut items (Array i64)) (&mut items)]
    [n : i64 (array-ref items 0)]
    (begin
      (array-set! borrowed 0 41)
      n)))