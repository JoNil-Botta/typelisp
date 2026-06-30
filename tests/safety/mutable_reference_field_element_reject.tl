;: SPEC borrow contract: mutable borrows conflict across ancestor/descendant paths.
(import stdlib.array)

(defstruct Bags
  (left (Array i64))
  (right (Array i64)))

(define (main) : unit
  (let
    [left-items : (Array i64) (array.make-array i64 1)]
    [right-items : (Array i64) (array.make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [whole-left : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      [first-item : (&mut bags i64) (&mut (array-ref (struct-get bags left) 0))]
      unit)))