;; A rank-2 domain whose element count exceeds i64 traps through the
;; bounds-check abort path before the body runs, in every backend mode
;; (#7190). Each span alone fits.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach ([y : i64 0 h] [x : i64 0 w]) (set! (array-ref out (+ (* y w) x)) 1)))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (fill (&mut out) 4294967296 2147483648)
      (array-ref out 0))))