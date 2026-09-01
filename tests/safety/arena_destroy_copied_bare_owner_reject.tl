(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [copied : arena.Arena owner]
    (begin
      (arena.destroy-safe! copied)
      42)))