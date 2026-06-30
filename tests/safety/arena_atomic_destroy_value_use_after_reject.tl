(import stdlib.arena)
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [text : String (in-arena owner (append "owned" "-text"))]
    (begin
      (arena.destroy-safe! owner)
      (string-length text))))
