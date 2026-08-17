(import stdlib.arena)

(define (needs-brand [_owner : (arena.Arena owner)]) : i64
  42)

(define (main) : i64
  (let
    [legacy : arena.Arena (arena.make)]
    (needs-brand legacy)))