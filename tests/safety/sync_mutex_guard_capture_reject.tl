;: Mutex guards are cleanup resources and cannot be captured by closures.
(import "stdlib/sync.tl")
(import (mutex i64) as mutex_i64)

(define (bad [mutex : mutex_i64.Mutex]) : i64
  (with
    ([guard (mutex_i64.lock mutex) mutex_i64.unlock])
    ((lambda () : i64
        (mutex_i64.get guard)))))

(define (main) : i64
  0)