;: SPEC safe-code contract: safe code rejects overlapping mutable borrows.
(define (main [n : i64]) : unit
  (let
    [r : (&mut n i64) (&mut n)]
    (let
      [s : (&mut n i64) (&mut n)]
      unit)))