;: SPMD foreach bodies do not support scalar continue.
(define (main [n : i64]) : i64
  (begin
    (foreach
      ([i : i64 0 n])
      (while true
        (continue)))
    0))