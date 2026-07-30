;: #2610: non-call dotted mutable borrows retain the rooted field path.
(import stdlib.array)

(defstruct Pair
  (left (__tl_dyn-array i64))
  (right (__tl_dyn-array i64)))

(define (main) : unit
  (let
    [left : (__tl_dyn-array i64) (array.make-array i64 1)]
    [right : (__tl_dyn-array i64) (array.make-array i64 1)]
    [pair : Pair (Pair left right)]
    [first : (&mut pair (__tl_dyn-array i64)) (&mut pair.left)]
    [second : (&mut pair (__tl_dyn-array i64)) (&mut pair.left)]
    unit))