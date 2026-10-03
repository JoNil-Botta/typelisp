;; A fixed-array gather source keeps the ordinary per-lane bounds check (#8346).
;; Lanes 1 and 3 are invalid in one full gang; every mode checks logical lanes
;; in order before the hardware gather, so each aborts on lane 1's index.
(define table : (Array i64 8)
  (array 10 11 12 13 14 15 16 17))

(define (main) : i64
  (let
    [ix : (Array i64 8) (array 0 99 1 -1 2 3 4 5)]
    [out : (Array i64 8) (make-array i64 8)]
    (foreach
      ([i : i64 0 8])
      (set! (array-ref out i) (array-ref table (array-ref ix i))))
    (array-ref out 0)))