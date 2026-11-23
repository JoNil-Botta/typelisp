;; Multi-latch loop with a store-free continue backedge and an array-push on
;; the other backedge: merged natural-loop bodies ensure load-GVN does not treat
;; array-length as loop-invariant across the push. Expected exit 8 at opt0/1/2.
(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [sum : i64 0]
    [i : i64 0]
    (while (< i 4)
      (+= i 1)
      (+= sum (array-length a))
      (when (= i 2) (continue))
      (__tl_array-push! a i))
    sum))