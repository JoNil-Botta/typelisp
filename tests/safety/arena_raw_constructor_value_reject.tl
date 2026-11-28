(import stdlib.arena)

(define (main) : i64
  (let
    [construct arena.Arena]
    (arena.raw-handle (construct 0))))