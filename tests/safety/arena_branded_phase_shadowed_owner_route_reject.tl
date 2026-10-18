(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [_phase (arena.phase owner)]
    [_inner
      (let
        [owner (arena.make)]
        [phase (arena.phase owner)]
        (arena.rewind-safe! phase)
        (arena.destroy-safe! owner)
        0)]
    [_text (in-arena owner (string.append "outer" "-still-live"))]
    42))