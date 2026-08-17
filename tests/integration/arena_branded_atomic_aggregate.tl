(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(defstruct AtomicArenaState
  (:lifetimes owner)
  (arena (arena.Arena owner))
  (answer i64))

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [state (AtomicArenaState owner 42)]
    (match (thread_i64.spawn
      (lambda () : i64
        state.answer))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))