;: SPMD scans stay outside a foreach-active body.
(define (main) : i64
  (begin
    (foreach
      ([i : i64 0 4])
      (foreach-active
        [lane : i64]
        (spmd-scan sum ([j : i64 0 4] [prefix : i64 0]) j unit)))
    0))