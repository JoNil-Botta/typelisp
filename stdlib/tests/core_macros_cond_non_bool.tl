(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(define (main) : i64
  (core/cond 1 42 0))