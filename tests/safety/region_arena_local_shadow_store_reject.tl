;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for a fresh arena borrow stored to
;; the caller after a local named like the arena. Storing data bound before such
;; a local is the pre-existing binder-identity residual #9609, which this rule
;; does not change for non-colliding arenas.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : i64 1]
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)