;: SPEC SPMD contract: supported masked-if shape is classified but lowering is gated.
(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64] [offset : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (if (> (array-ref xs i) 0)
      (let
        [v : i64 (+ (array-ref xs i) 1)]
        (begin
          (if (< v 10)
            (array-set! out (+ i offset) v)
            (array-set! out (+ i offset) (+ v 1)))
          unit))
      (array-set! out (+ i offset) 0))))