(define (main) : i64
  (spmd-compact
    ([i : i64 0 3] [slot : i64 0])
    true
    (begin
      (spmd-compact ([j : i64 0 1] [inner : i64 slot]) true unit)
      unit)))