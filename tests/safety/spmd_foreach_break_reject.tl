;: SPMD foreach bodies do not support scalar break.
(define (main [n : i64]) : i64
  (begin
    (foreach
      ([i : i64 0 n])
      (while true
        (break)))
    0))