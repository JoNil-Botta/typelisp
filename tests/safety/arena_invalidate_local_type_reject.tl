(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : (:invalidate r (arena.Arena r)) (arena.make)]
    42))