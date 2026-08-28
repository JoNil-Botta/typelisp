(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import stdlib.string)

(defstruct OrdinaryArenaState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (text (in owner String)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "ordinary" "-owned"))]
    [state (OrdinaryArenaState owner text)]
    (match (thread_i64.spawn
      (lambda () : i64
        (string.string-length state.text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))