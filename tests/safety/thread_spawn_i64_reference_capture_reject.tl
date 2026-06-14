(import "stdlib/thread.tl")

(define (read-ref [r : (& n i64)]) : i64
  42)

(define (main) : i64
  (let
    [n : i64 41]
    [r : (& n i64) (& n)]
    (match (thread-spawn-i64
      (lambda () : i64
        (read-ref r)))
      [(ThreadI64SpawnErr _) 1]
      [(ThreadI64SpawnOk thread)
        (match (thread-join-i64 thread)
          [(ThreadI64JoinOk value) value]
          [(ThreadI64JoinErr _) 2])])))