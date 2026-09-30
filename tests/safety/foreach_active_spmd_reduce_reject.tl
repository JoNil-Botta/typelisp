;: SPMD reductions stay outside a foreach-active body.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active
          [lane : i64]
          (set! total (spmd-reduce sum ([j : i64 0 4]) 0 j))))
      total)))