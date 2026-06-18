(import "stdlib/thread.tl")

(define (main) : i64
  (let
    [cell : (Box i64) (box 41)]
    (match (thread-spawn-box-i64
      (lambda () : (Box i64)
        cell))
      [(ThreadBoxI64SpawnErr _) 1]
      [(ThreadBoxI64SpawnOk worker)
        (match (thread-join-box-i64 worker)
          [(ThreadBoxI64JoinOk joined) (box-get joined)]
          [(ThreadBoxI64JoinErr _) 2])])))