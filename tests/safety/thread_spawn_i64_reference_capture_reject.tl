(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (read-ref [r : (& n i64)]) : i64
  42)

(define (main) : i64
  (let
    [n : i64 41]
    [r : (& n i64) (& n)]
    (match (thread_i64.spawn
      (lambda () : i64
        (read-ref r)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk thread)
        (match (thread_i64.join thread)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))