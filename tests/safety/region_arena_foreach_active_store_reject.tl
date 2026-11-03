;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for arena data stored to the
;; caller from a `foreach-active` body.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      (foreach
        ([i : i64 0 1])
        (foreach-active [r : i64] (set! b.value (& (deref x))))))))

(define (main) : i64
  0)