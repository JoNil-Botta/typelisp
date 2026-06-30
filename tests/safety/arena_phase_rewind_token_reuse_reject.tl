(import "stdlib/arena.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make)]
    [phase : ArenaPhase (arena-phase owner)]
    [text : String (in-arena owner (string-append "temp" "-text"))]
    (begin
      (string-length text)
      (arena-rewind-safe! phase)
      (arena-rewind-safe! phase)
      42)))