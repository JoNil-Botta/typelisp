(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [text : String (in-arena owner (string.append "owned" "-text"))]
    (match (thread_i64.spawn
      (lambda () : i64
        (string-length text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (begin
          (arena.destroy-safe! owner)
          (match (thread_i64.join worker)
            [(thread_i64.I64JoinOk value) value]
            [(thread_i64.I64JoinErr _) 2]))])))
