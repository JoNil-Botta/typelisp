;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for an escape stored before a
;; lambda with a parameter spelled like the arena.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      (set! b.value (& (deref x)))
      (let
        [f
          (lambda ([r : i64]) : i64
            r)]
        unit))))

(define (main) : i64
  0)