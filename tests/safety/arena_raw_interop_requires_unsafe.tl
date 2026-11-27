(import stdlib.arena)

(define (main) : i64
  (arena.raw-handle (arena.from-raw-handle 0)))