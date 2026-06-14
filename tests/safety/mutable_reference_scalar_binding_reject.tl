;: SPEC borrow contract: bound scalar mutable borrows need scope writeback.
(define (main [n : i64]) : unit
  (let
    [r : (&mut n i64) (&mut n)]
    unit))