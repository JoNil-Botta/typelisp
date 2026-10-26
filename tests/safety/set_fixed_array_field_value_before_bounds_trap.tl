;; A field of a fixed-array element owes the final bounds check: the value's
;; trap comes first.
(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [a : (Array Pair 1) (array (Pair 1 2))]
    [i : i64 1]
    (set! (array-ref a i).b (shl (cast 1 : i64) -1))
    0))