(import stdlib.arena)

(define (main) : i64
  (let
    [construct arena.Arena]
    (construct 12345).handle))