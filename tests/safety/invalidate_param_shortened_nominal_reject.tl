;; Refs #9503: a nominal value shortened as a whole keeps the brand it stores.
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64))
  (n i64))

(define (exercise [owner : (arena.Arena r) (:invalidate r)] [v : (View r)]) : i64
  (let
    [k : i64 5]
    (let
      [w : (View k) v]
      (begin
        (arena.destroy-safe! owner)
        (deref w.p)))))

(define (main) : i64
  0)
