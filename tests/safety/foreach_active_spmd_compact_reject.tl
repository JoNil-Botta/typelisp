;: SPMD compaction stays outside a foreach-active body.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active
          [lane : i64]
          (set! total (spmd-compact ([j : i64 0 4] [slot : i64 0]) true unit))))
      total)))