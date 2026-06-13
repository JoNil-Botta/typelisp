(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(define (main) : i64
  (core/cond true 42 false))