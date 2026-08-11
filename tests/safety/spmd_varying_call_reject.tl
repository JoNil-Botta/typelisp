;: SPEC SPMD v1 private-call ABI: function-value varying calls stay rejected.
(import stdlib.array)

(define (inc [x : i64]) : i64
  (+ x 1))

(define (main
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (let
    [f : (-> i64 i64) inc]
    (foreach ([i : i64 0 n]) (set! (array-ref out i) (f (array-ref xs i))))))