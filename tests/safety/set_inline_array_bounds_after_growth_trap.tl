;; Growth cannot drop the pending inner check or retarget its captured index.
(import stdlib.io)

(defstruct Row
  (tag i64)
  (cells (Array i64 3)))

(define (main) : i64
  (let
    [a : (__tl_dyn-array Row) (__tl_make-array Row 1)]
    [j : i64 3]
    (set!
      (array-ref (array-ref a 0).cells j)
      (begin
        (__tl_array-push! a (Row 2 (array 40 50 60)))
        (io.println "RHS grew")
        (set! j 0)
        70))
    0))