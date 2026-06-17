;: SPEC borrow contract: overlapping mutable borrows of the same field reject.
(defstruct Bags
  (left (Array i64))
  (right (Array i64)))

(define (main) : unit
  (let
    [left-items : (Array i64) (make-array i64 1)]
    [right-items : (Array i64) (make-array i64 1)]
    [bags : Bags (Bags left-items right-items)]
    (let
      [first : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      [second : (&mut bags (Array i64)) (&mut (struct-get bags left))]
      unit)))