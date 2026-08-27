;: SPEC borrow contract: element reads conflict with an overlapping live
;: mutable owner borrow.
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [borrowed : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-ref items 0)]
    (begin
      (set! (array-ref borrowed 0) 41)
      n)))