(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [text : String "not-transferable"]
    (match (thread-spawn-i64
      (lambda () : i64
        (string-length text)))
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk thread)
        (match (thread-join-i64 thread)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2])])))
