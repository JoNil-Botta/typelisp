(import stdlib.arena)

(define (main) : unit
  (unsafe
    (arena.rewind (arena.current))))