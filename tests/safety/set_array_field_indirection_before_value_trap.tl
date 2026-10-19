(defstruct Pair
  (a i64)
  (b i64))

(defstruct Holder
  (value (Box Pair)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Holder) (__tl_make-array Holder 0)]
    (set! (deref (array-ref a 0).value).b (shl (cast 1 : i64) -1))
    0))