;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for arena data stored to the
;; caller from a shadowing local's initializer.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [r : i64
        (begin
          (set! b.value (& r (deref x)))
          1)]
      unit)))

(define (main) : i64
  0)