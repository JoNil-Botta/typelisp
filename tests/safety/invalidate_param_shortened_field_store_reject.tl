;; Known conservative rejection (#9503; flow-sensitive kill: #9464, #9256): a
;; value that keeps a stored brand cannot be stored into a field of a
;; body-local value, even with no use after the end.
(import stdlib.arena)

(defstruct Cell
  (:lifetimes a)
  (p (& a i64)))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [x : (& r i64)]) : i64
  (let
    [k : i64 5]
    (let
      [c : (Cell k) (Cell (& k))]
      (begin
        (set! c.p x)
        (arena.destroy-safe! owner)
        0))))

(define (main) : i64
  0)