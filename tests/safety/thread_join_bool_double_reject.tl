(import "stdlib/thread.tl")
(import (thread-handle bool) as thread_bool)

(define (main) : i64
  (match (thread_bool.spawn
    (lambda () : bool
      true))
    [(thread_bool.BoolSpawnErr _) 1]
    [(thread_bool.BoolSpawnOk worker)
      (begin
        (thread_bool.join worker)
        (match (thread_bool.join worker)
          [(thread_bool.BoolJoinOk value)
            (if value
              42
              3)]
          [(thread_bool.BoolJoinErr _) 2]))]))