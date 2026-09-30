(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)] [early : bool]) : unit
  (begin
    (if early
      (return unit)
      unit)
    (arena.destroy-safe! owner)))

(define (main) : i64
  42)