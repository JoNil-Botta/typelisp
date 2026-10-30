;; Refs #9098: inside `(in-arena owner ...)`, `(with-arena r ...)` marks and
;; resets the owner's own arena. Destroying the owner there would leave the
;; reset to run on a destroyed arena, so it is rejected, as on main, which
;; matches the shared spelling of the owner's brand `r`.
(import stdlib.arena)

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (in-arena
    owner
    (with-arena
      r
      (begin
        (arena.destroy-safe! owner)
        42))))

(define (main) : i64
  (let
    [owner (arena.make)]
    (exercise owner)))