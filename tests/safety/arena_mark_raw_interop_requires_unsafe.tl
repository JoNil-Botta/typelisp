(import stdlib.arena)

(define (main) : i64
  (arena.mark-raw-handle (arena.mark-from-raw-handle 0)))