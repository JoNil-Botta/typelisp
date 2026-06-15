(import "stdlib/thread.tl")

(define (main) : i64
  (match (thread-spawn-bool
    (lambda () : bool
      true))
    [(ThreadBoolSpawnErr _) 1]
    [(ThreadBoolSpawnOk worker)
      (begin
        (thread-join-bool worker)
        (match (thread-join-bool worker)
          [(ThreadBoolJoinOk value)
            (if value
              42
              3)]
          [(ThreadBoolJoinErr _) 2]))]))