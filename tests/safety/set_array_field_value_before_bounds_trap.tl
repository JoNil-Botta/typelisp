(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Pair) (__tl_make-array Pair 0)]
    (set! (array-ref a 0).b (shl (cast 1 : i64) -1))
    0))