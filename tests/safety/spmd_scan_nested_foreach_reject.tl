;: SPEC SPMD contract: scan bodies reject nested public SPMD constructs.
(define (bad [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    (array-ref xs i)
    (foreach ([j : i64 0 n]) (array-set! out j prefix))))