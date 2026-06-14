;: SPEC safe-code contract: safe code rejects overlapping mutable borrows.
(define (main [items : (Array i64)]) : unit
  (let
    [r : (&mut items i64) (&mut (array-ref items 0))]
    (let
      [s : (&mut items i64) (&mut (array-ref items 0))]
      unit)))