(import stdlib.arena)

(define (destroy-moved-input [owner : (arena.Arena owner)]) : unit
  (let
    [local : (arena.Arena owner) owner]
    (arena.destroy-safe! local)))

(define (main) : i64
  42)