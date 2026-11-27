(import stdlib.arena)

(define (forge [handle : i64]) : arena.Arena
  (arena.Arena handle))

(define (main) : i64
  (arena.raw-handle (forge 0)))