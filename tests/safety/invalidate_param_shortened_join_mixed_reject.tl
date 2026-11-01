;; Refs #9503: a shortened `if` join keeps the brand of the branch that stores it,
;; even when the other branch is body-local.
(import stdlib.arena)

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& r i64)]
  [c : bool]) : i64
  (let
    [k : i64 5]
    [alias : (& k i64) (if c x (& k))]
    (begin
      (arena.destroy-safe! owner)
      (deref alias))))

(define (main) : i64
  0)
