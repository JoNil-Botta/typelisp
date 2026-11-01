;; Refs #9503: skip a phantom first brand, retaining the second stored brand.
(import stdlib.arena)

(defstruct View
  (:lifetimes phantom stored)
  (p (& stored i64)))

(define (exercise
  [first : (arena.Arena r) (:invalidate r)]
  [second : (arena.Arena s) (:invalidate s)]
  [x : (& a (View r s))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (View k k)) x]
    (arena.destroy-safe! second)
    (deref alias).p
    (arena.destroy-safe! first)
    0))

(define (main) : i64
  0)