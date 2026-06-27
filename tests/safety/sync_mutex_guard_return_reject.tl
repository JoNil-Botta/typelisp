;: Mutex guards cannot escape their cleanup scope.
(import "stdlib/sync.tl")
(import (mutex i64) as mutex_i64)

(define (bad [mutex : mutex_i64.Mutex]) : mutex_i64.Guard
  (with ([guard (mutex_i64.lock mutex) mutex_i64.unlock]) guard))

(define (main) : i64
  0)