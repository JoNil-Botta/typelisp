;; Refs #9508: a value constructed from a reference with a stored brand keeps
;; that brand at a body-local lifetime, so the end invalidates it.
(import stdlib.arena)

(defstruct Cell
  (:lifetimes a)
  (p (& a i64)))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [c : (Cell k) (Cell x)]
      (begin
        (arena.destroy-safe! owner)
        (deref c.p)))))

(define (main) : i64
  0)
