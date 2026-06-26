;: SPEC safe-code contract: safe code rejects overlapping mutable borrows.
;: Compatibility exception for #3772: borrow-place syntax still requires the
;: bare array-ref alias until qualified array macro calls become places.
(import stdlib.array)

(define (main [items : (Array i64)]) : unit
  (let
    [r : (&mut items i64) (&mut (array-ref items 0))]
    (let
      [s : (&mut items i64) (&mut (array-ref items 0))]
      unit)))