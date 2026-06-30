(import stdlib.arena)

(define (main) : i64
  (let
    [make : (-> arena.Arena)
      (lambda () : arena.Arena
        (arena.current))]
    [owner : arena.Arena (make)]
    [phase : arena.ArenaPhase (arena.phase owner)]
    (begin
      (arena.rewind-safe! phase)
      42)))