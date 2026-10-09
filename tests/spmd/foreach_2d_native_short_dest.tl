;; Rank-2 row-local gangs (#7191): the destination is one element short of the
;; domain, so rows 0 and 1 fit and the last element of row 2 is the first
;; out-of-bounds store. Every mode aborts with the checked-access trap at that
;; element; no gang writes past the array.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [w : i64]) : unit
  (foreach
    ([y : i64 0 3] [x : i64 0 w])
    (set! (array-ref out (+ (* y w) x)) (+ (* y 16) x))))

(define (main) : i64
  (let
    [w : i64 13]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 (- (* 3 w) 1))]
    (fill (&mut out) w)
    0))