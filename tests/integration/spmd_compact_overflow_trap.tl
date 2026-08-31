; A selected lane at i64::MAX must trap before evaluating its body (#7083).
(define (main) : i64
  (spmd-compact
    ([i : i64 0 1] [slot : i64 9223372036854775807])
    true
    (begin
      (/ 1 0)
      unit)))