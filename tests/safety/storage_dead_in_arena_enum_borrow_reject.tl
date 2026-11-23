;; #9288: an inline enum constructed inside `in-arena` lives in the local stack
;; frame, not the arena, so returning a borrow of it must fail E0205.
(import stdlib.arena)

(defenum Boxed
  (One (Box i64))
  (Empty))

(define (mk [a : (arena.Arena r)]) : (& r Boxed)
  (in-arena
    a
    (let
      [e (Boxed.One (box 42))]
      (& e))))

(define (main) : i64
  (let
    [owner (arena.make)]
    [r (mk owner)]
    (match r
      [(One b) (deref b)]
      [(Empty) 0])))