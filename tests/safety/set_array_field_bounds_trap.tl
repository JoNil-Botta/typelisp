(defstruct Pair
  (a i64)
  (b i64))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Pair) (__tl_make-array Pair 0)]
    (set!
      (array-ref a 1).b
      (begin
        (__tl_array-push! a (Pair 1 2))
        70))
    0))