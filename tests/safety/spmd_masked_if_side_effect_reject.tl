;: SPEC SPMD contract: masked-if branches reject non-contiguous side effects.
(import stdlib.array)

(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [tmp : i64 0]
      (if (> (array.array-ref xs i) 0)
        (set! tmp (array.array-ref xs i))
        (array.array-set! out i tmp)))))