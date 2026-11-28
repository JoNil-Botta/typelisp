;; Raw integers cannot manufacture safe arena authority.
(import stdlib.arena)

(define (main) : i64
  (let
    [owner : arena.Arena
      (unsafe
        (arena.Arena 0))]
    (arena.raw-handle owner)))