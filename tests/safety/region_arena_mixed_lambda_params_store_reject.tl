;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for arena data returned through a
;; lambda with mixed same-named parameters into caller storage.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [f
        (lambda ([r : i64] [r : (& r i64)]) : (& r i64)
          r)]
      ; Must fail: the arena `r` resets before the caller reads `b.value`.
      (set! b.value (f 1 (& r (deref x)))))))

(define (main) : i64
  0)