(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : (arena.Arena r)
  owner)

(define (main) : i64
  42)