(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [text : String (in-arena owner (string.append "owned" "-text"))]
    (begin
      (arena.destroy-safe! owner)
      (string-length text))))