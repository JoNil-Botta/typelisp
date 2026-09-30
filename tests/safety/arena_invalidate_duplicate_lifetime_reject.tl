(import stdlib.arena)
(import stdlib.string)

(define (release
  [a : (arena.Arena r) (:invalidate r)]
  [b : (arena.Arena r) (:invalidate r)]) : unit
  (begin
    (arena.destroy-safe! a)
    (arena.destroy-safe! b)))

(define (main) : i64
  42)