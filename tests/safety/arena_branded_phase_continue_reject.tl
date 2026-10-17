(import stdlib.arena)

(define (main) : i64
  (let
    [owner (arena.make)]
    [index : i64 0]
    (while (< index 2)
      (let
        [phase (arena.phase owner)]
        (+= index 1)
        (continue)))
    42))