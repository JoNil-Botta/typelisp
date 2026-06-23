(import "stdlib/arena.tl")

(define (main) : unit
  (unsafe
    (arena-rewind (arena-current))))