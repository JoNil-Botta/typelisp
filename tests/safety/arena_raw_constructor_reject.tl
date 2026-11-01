;; Raw integers cannot manufacture safe arena authority.
(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.Arena 12345)]
    owner.handle))