(import stdlib.arena)

(define (associate [owner : (arena.Arena r)] [_phase : (arena.ArenaPhase r g)]) : i64
  (arena.raw-handle owner))

(define (main) : i64
  (let
    [first (arena.make)]
    [second (arena.make)]
    [phase (arena.phase second)]
    (associate first phase)))