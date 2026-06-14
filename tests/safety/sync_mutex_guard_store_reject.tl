;: Ordinary aggregates cannot store mutex guards.
(import "stdlib/sync.tl")

(defstruct Bad
  (guard MutexI64Guard))

(define (main) : i64
  0)