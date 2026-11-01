;; Refs #9503, B2: ending a phantom brand leaves a binding whose only stored brand
;; is still live; the read before that brand's end is accepted, in either end
;; order of the two owners.
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
    [alias : (& k (View k s)) x]
    (arena.destroy-safe! first)
    (deref alias).p
    (arena.destroy-safe! second)
    0))

(define (reversed
  [first : (arena.Arena r) (:invalidate r)]
  [second : (arena.Arena s) (:invalidate s)]
  [x : (& a (View s r))]) : i64
  (let
    [k : i64 0]
    [alias : (& k (View k r)) x]
    (arena.destroy-safe! second)
    (deref alias).p
    (arena.destroy-safe! first)
    0))

(define (main) : i64
  0)