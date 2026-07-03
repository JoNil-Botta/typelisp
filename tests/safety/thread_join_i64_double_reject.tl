(import stdlib.thread)
(import (thread.handle i64) as thread_i64)

(define (main) : i64
  (match (thread_i64.spawn
    (lambda () : i64
      42))
    [(thread_i64.I64SpawnErr _) 1]
    [(thread_i64.I64SpawnOk worker)
      (begin
        (thread_i64.join worker)
        (match (thread_i64.join worker)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2]))]))