;; #9288: an inline struct constructed inside `in-arena` lives in the local
;; stack frame, not the arena, so returning a borrow of it must fail E0205.
(import stdlib.arena)

(defstruct Pair
  (b (Box i64))
  (n i64)
  (m i64))

(define (mk [a : (arena.Arena r)]) : (& r Pair)
  (in-arena
    a
    (let
      [p (Pair (box 42) 1 2)]
      (& p))))

(define (main) : i64
  (let
    [owner (arena.make)]
    [r (mk owner)]
    (+ r.n r.m)))