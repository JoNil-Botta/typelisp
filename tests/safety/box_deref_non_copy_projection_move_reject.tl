;: Moving a non-Copy field out through `(deref box)` consumes the whole box
;: (the ownership graph tracks it, #8449); the box is unusable afterwards.
(import stdlib.string)

(defstruct Leaf
  (w i64)
  (s String))

(define (main) : i64
  (let
    [b : (Box Leaf) (box (Leaf 2 "s"))]
    [s : String (deref b).s]
    (string.string-length s)))