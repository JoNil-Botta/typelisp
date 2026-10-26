;: A returned reference ends at its last use; the owner is usable after it.
(defstruct Pair
  (left (__tl_dyn-array i64))
  (right i64))

(define (left-of [pair : (& pair Pair)]) : (& pair (__tl_dyn-array i64))
  (& pair.left))

(define (main) : i64
  (let
    [pair : Pair (Pair (__tl_make-array i64 2) 0)]
    [left : (& pair (__tl_dyn-array i64)) (left-of (& pair))]
    [n : i64 (array-length left)]
    (begin
      (set! pair.right 40)
      (+ n pair.right))))