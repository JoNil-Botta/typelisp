(import "stdlib/arena.tl")
(import "stdlib/thread.tl")
(import (thread-handle i64) as thread_i64)

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    (match (thread_i64.spawn
      (lambda () : i64
        (arena-raw-handle owner)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk thread)
        (match (thread_i64.join thread)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))