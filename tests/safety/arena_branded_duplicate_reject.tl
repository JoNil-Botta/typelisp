(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [_moved owner]
    (arena.raw-handle owner)))