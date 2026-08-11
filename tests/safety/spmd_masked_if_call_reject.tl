;: SPEC SPMD v1 private-call ABI: masked branches reject function-value calls.
(import stdlib.array)

(define (bump [x : i64]) : i64
  (+ x 1))

(define (main
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [f : (-> i64 i64) bump]
    (foreach
      ([i : i64 0 n])
      (if (> (array-ref xs i) 0)
        (set! (array-ref out i) (f (array-ref xs i)))
        (set! (array-ref out i) 0)))))