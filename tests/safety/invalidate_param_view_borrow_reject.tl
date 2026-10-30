;; Known conservative rejection (#9503; #9464, #9256): a by-value view that
;; names the brand carries the arena region, so borrowing it for a helper before
;; the end is rejected at the end, as main does for an `(in r (View r))`
;; parameter.
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64))
  (n i64))

(define (peek [v : (& b (View a))]) : i64
  (deref (deref v).p))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [v : (View r)]) : i64
  (let
    [s : i64 (peek (& v))]
    (begin
      (arena.destroy-safe! owner)
      s)))

(define (main) : i64
  0)