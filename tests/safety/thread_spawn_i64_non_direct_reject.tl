(import "stdlib/thread.tl")

(define (main) : i64
  (let
    [task : (-> i64)
      (lambda () : i64
        42)]
    (match (thread-spawn-i64 task)
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk thread)
        (match (thread-join-i64 thread)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2])])))