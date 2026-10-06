;: A rank-2 inner coordinate alone repeats for every outer coordinate, so
;: `out[x]` is not a full-domain disjoint write.
(define (fill [out : (&mut out (__tl_dyn-array i64))] [h : i64] [w : i64]) : unit
  (foreach ([y : i64 0 h] [x : i64 0 w]) (set! (array-ref out x) y)))

(define (main) : i64
  0)