(define (main) : i64
  (spmd-compact ([i : i64 0 3] [slot : i32 0]) true unit))