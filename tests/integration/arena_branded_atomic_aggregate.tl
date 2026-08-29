(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import stdlib.string)

(defstruct AtomicArenaState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (text (in owner String)))

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [text (in-arena owner (string.append "atomic branded arena " "allocation"))]
    [state (AtomicArenaState owner text)]
    (match (thread_i64.spawn
      (lambda () : i64
        (+ (string.string-length state.text) 11)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))