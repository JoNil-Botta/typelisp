(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [phase : ArenaPhase (arena-phase owner)]
    [text : String (in-arena owner (string-append "stale" "-text"))]
    (begin
      (arena-rewind-safe! phase)
      (string-length text))))