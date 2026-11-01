;; Refs #9508: a field projection keeps the stored brand through a shortening
;; annotation.
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64))
  (n i64))

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [v : (& r (View r))]) : i64
  (let
    [k : i64 5]
    (let
      [alias : (& k i64) (deref v).p]
      (begin
        (arena.destroy-safe! owner)
        (deref alias)))))

(define (main) : i64
  0)
