(import stdlib.arena)

(define (destroy-input [owner : (arena.Arena owner)]) : unit
  (arena.destroy-safe! owner))

(define (main) : i64
  42)