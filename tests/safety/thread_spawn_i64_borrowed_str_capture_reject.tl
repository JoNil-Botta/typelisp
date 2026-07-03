(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (borrowed-text-score [view : (& text str)]) : i64
  1)

(define (main) : i64
  (let
    [text : String "not-transferable"]
    [view : (& text str) (& text)]
    (match (thread_i64.spawn
      (lambda () : i64
        (borrowed-text-score view)))
      [(thread_i64.I64SpawnErr _) 2]
      [(thread_i64.I64SpawnOk thread)
        (match (thread_i64.join thread)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 3])])))