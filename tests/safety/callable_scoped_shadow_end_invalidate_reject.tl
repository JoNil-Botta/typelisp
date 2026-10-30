;; Refs #9098: `(with-arena r ...)` marks and resets the current arena, which
;; may be the incoming owner's own arena, so ending the incoming owner of brand
;; `r` inside it is rejected, as on main, which matches the shared spelling. A
;; scoped brand matches through its declaration key.
(import stdlib.arena)

(define (release [owner : (arena.Arena r) (:invalidate r)]) : unit
  (arena.destroy-safe! owner))

(define (exercise [owner : (arena.Arena r) (:invalidate r)]) : i64
  (with-arena
    r
    (begin
      (release owner)
      42)))

(define (main) : i64
  0)