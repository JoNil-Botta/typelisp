;: SPEC SPMD contract: indirect foreach calls with varying arguments are deferred.
(define (inc [x : i64]) : i64
  (+ x 1))

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 i64) inc]
    (foreach ([i : i64 0 n]) (array-set! out i (f (array-ref xs i))))))