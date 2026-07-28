(import stdlib.thread)
(import stdlib.vector)
(import (vector.vector i64) as i64-vec)

(define (main) : i64
  (let
    [items : i64-vec.Vec (i64-vec.new)]
    (match (thread.spawn-i64-vec
      (lambda () : i64-vec.Vec
        items))
      [(ThreadI64VecSpawnErr _) 1]
      [(ThreadI64VecSpawnOk worker)
        (match (thread.join-i64-vec worker)
          [(ThreadI64VecJoinOk joined) (i64-vec.len (& joined))]
          [(ThreadI64VecJoinErr _) 2])])))