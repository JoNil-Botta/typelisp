(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    (if true
      (begin
        (arena.phase owner)
        unit)
      unit)
    (let
      [text (in-arena owner (string.append "one" "-arm"))]
      (string.string-length text))))