(import "stdlib/thread.tl")

(define (borrowed-text-score [view : (& text str)]) : i64
  1)

(define (main) : i64
  (let
    [text : String "not-transferable"]
    [view : (& text str) (& text)]
    (match (thread-spawn-i64
      (lambda () : i64
        (borrowed-text-score view)))
      [(ThreadI64SpawnErr _) 2]
      [(ThreadI64SpawnOk thread)
        (match (thread-join-i64 thread)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 3])])))