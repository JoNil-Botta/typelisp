;; Refs #9502 Refs #9493. Brand/phase ids are not current binding boundaries.
(import stdlib.arena)
(define (main) : i64
  (let
    [o : arena.Arena (arena.make)]
    [phase : arena.ArenaPhase (arena.phase o)]
    (in-arena
      o
      (with-arena
        s
        (let
          [o : arena.Arena (arena.make)]
          (begin
            (arena.rewind-safe! phase)
            (arena.destroy-safe! o)
            42))))))
