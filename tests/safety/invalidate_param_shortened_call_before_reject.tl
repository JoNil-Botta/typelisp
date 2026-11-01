;; Known conservative rejection (#9503; #9464, #9256): a call requiring a
;; shortened reference can fail before the end, as for `(in r T)` parameters.
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64)))

(define (use-view [v : (& p (View p))]) : i64
  (deref v.p))

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& q (View r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (View k)) x]
    [read : i64 (use-view alias)]
    (arena.destroy-safe! owner)
    read))

(define (main) : i64
  0)