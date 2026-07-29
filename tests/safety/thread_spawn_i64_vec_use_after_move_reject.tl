(import stdlib.arena)
(import stdlib.thread)
(import stdlib.vector)
(import (vector.vector i64) as i64-vec)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [items : i64-vec.Vec
      (in-arena
        owner
        (let
          [out : i64-vec.Vec (i64-vec.new)]
          (begin
            (i64-vec.push (&mut out) 42)
            out)))]
    [spawned : ThreadI64VecSpawnResult
      (thread.spawn-i64-vec
        (lambda () : i64-vec.Vec
          items))]
    [after : i64 (i64-vec.len (& items))]
    (match spawned
      [(ThreadI64VecSpawnErr _) 1]
      [(ThreadI64VecSpawnOk worker)
        (match (thread.join-i64-vec worker)
          [(ThreadI64VecJoinOk _) after]
          [(ThreadI64VecJoinErr _) 2])])))