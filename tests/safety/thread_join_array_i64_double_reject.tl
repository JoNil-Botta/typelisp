(import "stdlib/thread.tl")

(define (main) : i64
  (match (thread-spawn-array-i64
    (lambda () : (Array i64)
      (make-array i64 1)))
    [(ThreadArrayI64SpawnErr _) 1]
    [(ThreadArrayI64SpawnOk worker)
      (begin
        (thread-join-array-i64 worker)
        (match (thread-join-array-i64 worker)
          [(ThreadArrayI64JoinOk items) (array-length items)]
          [(ThreadArrayI64JoinErr _) 2]))]))