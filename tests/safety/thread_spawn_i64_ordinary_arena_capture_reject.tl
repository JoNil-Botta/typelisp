(import "stdlib/arena.tl")
(import "stdlib/thread.tl")

(define (main) : i64
  (let
    [owner : i64 (arena-make)]
    (match (thread-spawn-i64
      (lambda () : i64
        owner))
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk thread)
        (match (thread-join-i64 thread)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2])])))