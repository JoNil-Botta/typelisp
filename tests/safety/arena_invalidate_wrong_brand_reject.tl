(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (let
    [other (arena.make)]
    (arena.destroy-safe! other)))

(define (main) : i64
  42)