;: SPEC SPMD contract: foreach bodies do not support function-local return.
(define (main [n : i64]) : i64
  (begin
    (foreach ([i : i64 0 n]) (return i))
    0))