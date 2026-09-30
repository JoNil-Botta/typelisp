(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (main) : i64
  (let
    [owner (arena.make)]
    (begin
      (in-arena owner (release owner))
      42)))