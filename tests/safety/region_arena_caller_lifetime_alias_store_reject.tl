;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for arena data passed through a
;; let and a lifetime-preserving call into caller storage.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (identity [p : (& t i64)]) : (& t i64)
  p)

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [y : (& r i64) (identity (& r (deref x)))]
      ; Must fail: `y` borrows the arena, which resets before the caller
      ; reads `b.value`.
      (set! b.value y))))

(define (main) : i64
  0)