;: SPEC borrow contract: overlapping mutable borrows of the same field reject.
(import stdlib.array)

(defstruct Bags
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))

(define (main) : unit
  (let
    [left-items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [right-items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [first : (&mut bags (__tl_dyn-array i64)) (&mut (struct-get bags left))]
      [second : (&mut bags (__tl_dyn-array i64)) (&mut (struct-get bags left))]
      unit)))