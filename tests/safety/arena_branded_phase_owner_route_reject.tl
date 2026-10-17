(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [text (in-arena owner (string.append "wrong" "-generation"))]
    (string.string-length text)))