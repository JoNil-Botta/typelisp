(import stdlib.arena)

(define (count [owner : (arena.Arena r)]) : i64
  2)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (+ 40 (count owner))))