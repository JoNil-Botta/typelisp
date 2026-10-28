;; An inline field projection preserves the inner element's final check.
(defstruct Pair
  (a i64)
  (b i64))

(defstruct Row
  (tag i64)
  (cells (Array Pair 3)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 1)]
    [j : i64 3]
    (set! (array-ref (array-ref a 0).cells j).b (shl (cast 1 : i64) -1))
    0))