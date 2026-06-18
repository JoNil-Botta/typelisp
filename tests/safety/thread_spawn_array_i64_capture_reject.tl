(import "stdlib/thread.tl")

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 1)]
    (match (thread-spawn-array-i64
      (lambda () : (Array i64)
        items))
      [(ThreadArrayI64SpawnErr _) 1]
      [(ThreadArrayI64SpawnOk worker)
        (match (thread-join-array-i64 worker)
          [(ThreadArrayI64JoinOk joined) (array-length joined)]
          [(ThreadArrayI64JoinErr _) 2])])))