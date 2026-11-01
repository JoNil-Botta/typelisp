;; Refs #9508: a named call's result keeps the stored brand of its argument
;; through a shortening annotation, so the end invalidates it.
(import stdlib.arena)

(define (id [p : (& a i64)]) : (& a i64)
  p)

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (id x)]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)
