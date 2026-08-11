;: SPEC SPMD contract: masked-if branches reject non-contiguous side effects.
(import stdlib.array)

(define (main
  [xs : (__tl_dyn-array i64)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [tmp : i64 0]
      (if (> (array-ref xs i) 0)
        (set! tmp (array-ref xs i))
        (set! (array-ref out i) tmp)))))