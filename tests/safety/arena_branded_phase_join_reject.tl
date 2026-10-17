(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    (if true
      (arena.rewind-safe! phase)
      unit)
    (let
      [text (in-arena owner (string.append "one" "-arm"))]
      (string.string-length text))))