;: Scan bodies run for effects and must have type unit.
(define (bad [xs : (Array i64)] [n : i64]) : unit
  (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) prefix))