;; Multi-latch loop with a store-free continue backedge and a dyn-array element
;; store on the other backedge: merged natural-loop bodies ensure load-GVN sees
;; the element write across continue iterations. Expected exit 13 at opt0/1/2.
(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [i : i64 0]
    (set! (array-ref a 0) 10)
    (while (< i 4)
      (+= i 1)
      (when (= i 2) (continue))
      (set! (array-ref a 0) (+ (array-ref a 0) 1)))
    (array-ref a 0)))