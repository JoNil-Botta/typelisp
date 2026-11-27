(import stdlib.arena)

(define (main) : i64
  (unsafe
    (arena.mark-raw-handle (arena.ArenaMark 0))))