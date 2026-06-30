;: Mutex guards must be owned by `with`, not ordinary `let`.
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)

(define (bad [mutex : mutex_i64.Mutex]) : i64
  (let
    [guard : mutex_i64.Guard (mutex_i64.lock mutex)]
    (mutex_i64.get guard)))

(define (main) : i64
  0)