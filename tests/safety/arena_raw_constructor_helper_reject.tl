(import stdlib.arena)

(define (forge [handle : i64]) : arena.Arena
  (arena.Arena handle))

(define (main) : i64
  (forge 12345).handle)