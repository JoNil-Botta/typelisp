(import stdlib.arena)
(import stdlib.string)

(define (allocate [owner : (arena.Arena r)]) : (in r String)
  (in-arena owner (string.append "owner" "-route")))

(define (main) : i64
  (let
    [owner (arena.make)]
    [phase (arena.phase owner)]
    [text (allocate owner)]
    (arena.rewind-safe! phase)
    (string.string-length text)))