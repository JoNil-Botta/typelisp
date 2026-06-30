(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (begin
      (in-arena owner (arena.destroy-safe! owner))
      42)))