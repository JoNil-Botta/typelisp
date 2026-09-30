(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)] [now : bool]) : unit
  (if now
    (arena.destroy-safe! owner)
    unit))

(define (main) : i64
  42)