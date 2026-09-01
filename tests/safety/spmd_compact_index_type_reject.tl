(define (main) : i64
  (spmd-compact ([i : u32 0 3] [slot : i64 0]) true unit))