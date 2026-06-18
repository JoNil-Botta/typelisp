(import "stdlib/thread.tl")

(define (main) : i64
  (match (thread-spawn-box-i64
    (lambda () : (Box i64)
      (box 42)))
    [(ThreadBoxI64SpawnErr _) 1]
    [(ThreadBoxI64SpawnOk worker)
      (begin
        (thread-join-box-i64 worker)
        (match (thread-join-box-i64 worker)
          [(ThreadBoxI64JoinOk cell) (box-get cell)]
          [(ThreadBoxI64JoinErr _) 2]))]))