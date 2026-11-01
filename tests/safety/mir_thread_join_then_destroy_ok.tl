;; Joining the thread releases its use of the atomic arena: the destroy after
;; the join is accepted.
(import stdlib.arena)
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [text : String (in-arena owner (string.append "owned" "-text"))]
    (match (thread_i64.spawn
      (lambda () : i64
        (string-length text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (let
          [length : i64
            (match (thread_i64.join worker)
              [(thread_i64.I64JoinOk value) value]
              [(thread_i64.I64JoinErr _) 2])]
          (begin
            (arena.destroy-safe! owner)
            length))])))