;: SPEC SPMD v1 private-call ABI: masked branches reject function-value calls.
(import stdlib.array)

(define (bump [x : i64]) : i64
  (+ x 1))

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 i64) bump]
    (foreach
      ([i : i64 0 n])
      (if (> (array.array-ref xs i) 0)
        (array.array-set! out i (f (array.array-ref xs i)))
        (array.array-set! out i 0)))))