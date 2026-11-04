;; Rejected at entry: the arena is named like the caller lifetime `r` of a
;; `&mut` parameter, so the form fails with the collision diagnostic and the
;; arena must be renamed (#9593, D-C121). It was the review witness for the
;; original #9593 escape: a borrow of arena data stored into the caller's
;; struct.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      ; Must fail: the arena `r` resets before the caller reads `b.value`.
      (set! b.value (& (deref x))))))

(define (main) : i64
  0)