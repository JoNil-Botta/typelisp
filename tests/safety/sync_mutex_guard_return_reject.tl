;: Mutex guards cannot escape their cleanup scope.
(import "stdlib/sync.tl")

(define (bad [mutex : MutexI64]) : MutexI64Guard
  (with ([guard (mutex-i64-lock mutex) mutex-i64-unlock]) guard))

(define (main) : i64
  0)