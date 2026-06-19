;: Lane identity forms are not valid in spmd-scan bodies.
(define (bad [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    i
    (array-set! out i (program-index))))