(import stdlib.arena)

(define (main) : unit
  (arena.rewind (arena.mark)))