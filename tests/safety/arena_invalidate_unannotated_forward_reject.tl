(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (forward [owner : (arena.Arena s)]) : unit
  (release owner))

(define (main) : i64
  42)