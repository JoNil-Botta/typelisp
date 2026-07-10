;: #2610: non-call dotted mutable borrows retain the rooted field path.
(import stdlib.array)

(defstruct Pair
  (left (Array i64))
  (right (Array i64)))

(define (main) : unit
  (let
    [left : (Array i64) (array.make-array i64 1)]
    [right : (Array i64) (array.make-array i64 1)]
    [pair : Pair (Pair left right)]
    [first : (&mut pair (Array i64)) (&mut pair.left)]
    [second : (&mut pair (Array i64)) (&mut pair.left)]
    unit))