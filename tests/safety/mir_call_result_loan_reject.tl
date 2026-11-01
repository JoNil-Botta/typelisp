;: A reference returned by a call keeps its argument's loan alive.
(defstruct Pair
  (left (__tl_dyn-array i64))
  (right i64))

(define (left-of [pair : (& pair Pair)]) : (& pair (__tl_dyn-array i64))
  (& pair.left))

(define (run [pair : Pair]) : i64
  (let
    [left : (& pair (__tl_dyn-array i64)) (left-of (& pair))]
    (begin
      (set! pair.right 5)
      (array-length left))))

(define (main) : i64
  0)