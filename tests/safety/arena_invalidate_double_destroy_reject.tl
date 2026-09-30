(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (begin
    (arena.destroy-safe! owner)
    (arena.destroy-safe! owner)))

(define (main) : i64
  42)