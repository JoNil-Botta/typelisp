(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [text (in-arena phase (string.append "phase" "-value"))]
    [view (& text)]
    (arena.rewind-safe! phase)
    (string.string-length view)))