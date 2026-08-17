(import stdlib.arena)

(define (main) : i64
  (let
    [_owner
      (if true
        (arena.make)
        (arena.make))]
    0))