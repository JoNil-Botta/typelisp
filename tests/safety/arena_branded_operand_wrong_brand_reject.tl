(import stdlib.arena)

(define (same [left : (arena.Arena r)] [right : (arena.Arena r)]) : i64
  2)

(define (main) : i64
  (let
    [left (arena.make)]
    [right (arena.make)]
    (+ 40 (same left right))))