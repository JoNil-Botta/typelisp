;: A reduction value cannot contain nested public SPMD constructs.
(define (bad [xs : (Array i64)] [n : i64]) : i64
  (spmd-reduce
    sum
    ([i : i64 0 n])
    0
    (spmd-scan sum ([j : i64 0 n] [prefix : i64 0]) (array-ref xs j) unit)))