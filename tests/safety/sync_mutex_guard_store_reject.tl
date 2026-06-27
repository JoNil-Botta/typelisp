;: Ordinary aggregates cannot store mutex guards.
(import "stdlib/sync.tl")
(import (mutex i64) as mutex_i64)

(defstruct Bad
  (guard mutex_i64.Guard))

(define (main) : i64
  0)