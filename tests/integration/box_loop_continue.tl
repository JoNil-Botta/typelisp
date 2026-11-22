;; Multi-latch loop with a store-free continue backedge and a Box deref write
;; on the other backedge: natural loops sharing a header must merge bodies so
;; load-GVN sees the store on every iteration. Expected exit 13 at opt0/1/2.
(define (main) : i64
  (let
    [b : (Box i64) (box 10)]
    [i : i64 0]
    (while (< i 4)
      (+= i 1)
      (when (= i 2) (continue))
      (set! (deref b) (+ (deref b) 1)))
    (deref b)))