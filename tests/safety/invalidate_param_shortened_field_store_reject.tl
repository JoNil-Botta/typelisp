;; Known conservative rejection (#9503; #9464, #9256): a reference that carries
;; an arena region is not stored into a body-local struct field, as for
;; `(in r T)` parameters.
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