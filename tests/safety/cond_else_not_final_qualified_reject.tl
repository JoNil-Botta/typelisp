(import stdlib.core_macros as core)

(define (main) : i64
  (core.cond [else 0] [true 1]))