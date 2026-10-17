(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    (while (begin
      (arena.phase owner)
      false)
      unit)
    42))