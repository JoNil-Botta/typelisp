(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (main) : i64
  (let
    [cell : (Box i64) (box 42)]
    (match (thread_i64.spawn
      (lambda () : i64
        (box-get cell)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk thread)
        (match (thread_i64.join thread)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))