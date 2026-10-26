;; A field of a slice element owes the final bounds check: the value's trap
;; comes first.
(defstruct Pair
  (a i64)
  (b i64))

(define (write [s : (&mut a (Slice Pair))] [i : i64]) : unit
  (set! (array-ref s i).b (shl (cast 1 : i64) -1)))

(define (main) : i64
  (let
    [a : (Array Pair 1) (array (Pair 1 2))]
    (write (&mut a) 1)
    0))