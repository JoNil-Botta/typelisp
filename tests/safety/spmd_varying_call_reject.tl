;: SPEC SPMD contract: foreach calls with varying arguments are deferred.
(define (inc [x : i64]) : i64
  (+ x 1))

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (inc (array-ref xs i)))))