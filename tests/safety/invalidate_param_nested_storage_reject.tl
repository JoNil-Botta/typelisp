;; Refs #9503: variance must retain a real nested nominal storage dependency.
(import stdlib.arena)

(defstruct View
  (:lifetimes a)
  (p (& a i64)))

(defstruct Outer
  (:lifetimes a)
  (value (View a)))

(define (exercise
  [owner : (arena.Arena r) (:invalidate r)]
  [x : (& a (Outer r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (Outer k)) x]
    (arena.destroy-safe! owner)
    (deref alias).value.p
    0))

(define (main) : i64
  0)