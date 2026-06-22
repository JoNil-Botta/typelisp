(import "stdlib/thread.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [text : String "not-transferable"]
    (match (thread-spawn-bool
      (lambda () : bool
        (= (string-length text) 16)))
      [(ThreadBoolSpawnErr _) 1]
      [(ThreadBoolSpawnOk thread)
        (match (thread-join-bool thread)
          [(ThreadBoolJoinOk value)
            (if value
              42
              3)]
          [(ThreadBoolJoinErr _) 2])])))