;: SPEC SPMD contract: masked-if branches reject non-contiguous side effects.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (let
      [tmp : i64 0]
      (if (> (array-ref xs i) 0)
        (set! tmp (array-ref xs i))
        (array-set! out i tmp)))))