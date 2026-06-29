(import "stdlib/arena.tl")

(define (main) : i64
  (let
    [arena-make : (-> Arena)
      (lambda () : Arena
        (arena-current))]
    [owner : Arena (arena-make)]
    [phase : ArenaPhase (arena-phase owner)]
    (begin
      (arena-rewind-safe! phase)
      42)))