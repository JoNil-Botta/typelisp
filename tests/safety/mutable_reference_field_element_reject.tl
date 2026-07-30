;: SPEC borrow contract: mutable borrows conflict across ancestor/descendant paths.
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
      [whole-left : (&mut bags (__tl_dyn-array i64)) (&mut (struct-get bags left))]
      [first-item : (&mut bags i64) (&mut (array-ref (struct-get bags left) 0))]
      unit)))