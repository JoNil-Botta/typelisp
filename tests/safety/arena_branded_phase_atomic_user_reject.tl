(import stdlib.arena)
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "atomic" "-phase"))]
    (match (thread_i64.spawn
      (lambda () : i64
        (string.string-length text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (arena.rewind-safe! phase)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk _) 42]
          [(thread_i64.I64JoinErr _) 2])])))