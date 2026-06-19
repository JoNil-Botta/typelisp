;: SPEC SPMD scan contract: the range binding must use `[i : i64 start end]`.
(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan sum ([i 0 n] [prefix : i64 0]) (array-ref xs i) unit))