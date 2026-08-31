(define (main) : i64
  (spmd-compact ([i : i64 0 3] [slot : i64 0]) true (set! slot (+ slot 1))))