;: A mutex guard held by an ordinary `let` must be released or handed on before the scope ends.
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)

(define (bad [mutex : (& mutex mutex_i64.Mutex)]) : i64
  (let
    [guard : mutex_i64.Guard (mutex_i64.lock mutex)]
    (mutex_i64.get guard)))

(define (main) : i64
  0)