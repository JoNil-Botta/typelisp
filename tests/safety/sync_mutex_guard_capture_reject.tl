;: Mutex guards are cleanup resources and cannot be captured by closures.
(import "stdlib/sync.tl")

(define (bad [mutex : MutexI64]) : i64
  (with
    ([guard (mutex-i64-lock mutex) mutex-i64-unlock])
    ((lambda () : i64
        (mutex-i64-get guard)))))

(define (main) : i64
  0)