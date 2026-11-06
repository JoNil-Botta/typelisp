(define (main) : i64
  (comptime (+ 1 (cond [else 1] [false 2]))))