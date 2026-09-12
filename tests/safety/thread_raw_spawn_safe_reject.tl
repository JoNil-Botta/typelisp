;; Raw integer contexts do not carry ownership or publication proofs.
(import stdlib.thread)

(define (worker [value : i64]) : i64
  value)

(define (main) : i64
  (let
    [_result : thread.ThreadSpawnResult (thread.spawn worker 0)]
    0))