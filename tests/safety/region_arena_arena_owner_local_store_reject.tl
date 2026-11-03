;; A local arena owner spelled like a colliding with-arena region shadows it,
;; but a fresh borrow of arena data taken in its scope still cannot reach
;; caller storage (#9593).
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))] [owner : (arena.Arena r)]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : (arena.Arena r) owner]
      ; Must fail: the arena `r` resets before the caller reads `b.value`.
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)