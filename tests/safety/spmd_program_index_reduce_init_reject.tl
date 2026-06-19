;: Lane identity forms are not valid in spmd-reduce init expressions.
(define (bad [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) (program-index) i))