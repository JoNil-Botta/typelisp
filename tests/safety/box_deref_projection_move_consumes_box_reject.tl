;: Moving a non-Copy field out through `(deref box)` consumes the whole box,
;: so a later read of the box is a use after move (#8449).
(import stdlib.string)

(defstruct Leaf
  (w i64)
  (s String))

(define (main) : i64
  (let
    [b : (Box Leaf) (box (Leaf 2 "s"))]
    [s : String (deref b).s]
    (+ (string.string-length s) (deref b).w)))