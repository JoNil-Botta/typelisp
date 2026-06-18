(import "stdlib/thread.tl")

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (match (thread-spawn-i64
      (lambda () : i64
        (array-ref items 0)))
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk thread)
        (match (thread-join-i64 thread)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2])])))