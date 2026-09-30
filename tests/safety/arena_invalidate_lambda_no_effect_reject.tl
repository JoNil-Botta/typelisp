(import stdlib.arena)
(import stdlib.string)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (let
    [destroy
      (lambda () : unit
        (arena.destroy-safe! owner))]
    (destroy)))

(define (main) : i64
  42)