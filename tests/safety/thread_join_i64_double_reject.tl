(import "stdlib/thread.tl")

(define (main) : i64
  (match (thread-spawn-i64
    (lambda () : i64
      42))
    [(ThreadI64SpawnErr _) 1]
    [(ThreadI64SpawnOk worker)
      (begin
        (thread-join-i64 worker)
        (match (thread-join-i64 worker)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2]))]))