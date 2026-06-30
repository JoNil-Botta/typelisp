(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    [text : String (in-arena owner (string.append "owned" "-text"))]
    (begin
      (length text)
      (arena.destroy-safe! owner)
      (in-arena owner (string.append "after" "-destroy"))
      42)))