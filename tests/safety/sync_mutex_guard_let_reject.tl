;: Mutex guards must be owned by `with`, not ordinary `let`.
(import "stdlib/sync.tl")

(define (bad [mutex : MutexI64]) : i64
  (let
    [guard : MutexI64Guard (mutex-i64-lock mutex)]
    (mutex-i64-get guard)))

(define (main) : i64
  0)