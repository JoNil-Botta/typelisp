;: SPEC borrow contract: bound by-value mutable borrows need scope writeback.
(defstruct Pair
  (x i64)
  (y i64))

(define (main) : unit
  (let
    [p : Pair (Pair 1 2)]
    (let
      [r : (&mut p Pair) (&mut p)]
      unit)))