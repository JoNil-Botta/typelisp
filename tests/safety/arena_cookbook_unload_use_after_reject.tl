(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [level : arena.Arena (arena.make)]
    [name : String (in-arena level (string.append "level" "-name"))]
    (begin
      (arena.destroy-safe! level)
      (string.string-length name))))