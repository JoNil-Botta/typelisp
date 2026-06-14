;: SPEC SPMD contract: masked-if branches reject indirect varying calls.
(define (bump [x : i64]) : i64
  (+ x 1))

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 i64) bump]
    (foreach
      ([i : i64 0 n])
      (if (> (array-ref xs i) 0)
        (array-set! out i (f (array-ref xs i)))
        (array-set! out i 0)))))