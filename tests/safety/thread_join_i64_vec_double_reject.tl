(import stdlib.thread)
(import stdlib.vector)
(import (vector.vector i64) as i64-vec)

(define (main) : i64
  (match (thread.spawn-i64-vec
    (lambda () : i64-vec.Vec
      (i64-vec.new)))
    [(ThreadI64VecSpawnErr _) 1]
    [(ThreadI64VecSpawnOk worker)
      (begin
        (thread.join-i64-vec worker)
        (match (thread.join-i64-vec worker)
          [(ThreadI64VecJoinOk items) (i64-vec.len (& items))]
          [(ThreadI64VecJoinErr _) 2]))]))