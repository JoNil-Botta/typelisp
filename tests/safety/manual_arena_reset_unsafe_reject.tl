(import "stdlib/arena.tl")

(define (main) : unit
  (arena-rewind (arena-mark)))