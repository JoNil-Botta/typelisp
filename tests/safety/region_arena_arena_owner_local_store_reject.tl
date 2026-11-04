;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for a fresh arena borrow stored to
;; the caller after a local arena owner.
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