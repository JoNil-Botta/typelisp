(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (replace! owner.handle 12345)))