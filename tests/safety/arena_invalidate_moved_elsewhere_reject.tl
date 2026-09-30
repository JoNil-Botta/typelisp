(import stdlib.arena)
(import stdlib.string)

(define (keep [owner : (arena.Arena s)]) : unit
  unit)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (keep owner))

(define (main) : i64
  42)