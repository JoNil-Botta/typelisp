;: Task closure checking cannot bypass the global move restriction.
(import stdlib.string)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define global-text : String
  "task-owned")

(define (take-text [text : String]) : i64
  (string.string-length text))

(define (main) : i64
  (match (thread_i64.spawn
    (lambda () : i64
      (take-text global-text)))
    [(thread_i64.I64SpawnErr _) 1]
    [(thread_i64.I64SpawnOk thread)
      (match (thread_i64.join thread)
        [(thread_i64.I64JoinOk value) value]
        [(thread_i64.I64JoinErr _) 2])]))
