(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (unsafe
    (arena.destroy owner)))

(define (main) : i64
  42)