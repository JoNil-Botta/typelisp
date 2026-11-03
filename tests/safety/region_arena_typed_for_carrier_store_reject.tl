;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for a fresh arena borrow stored to
;; the caller from a typed `for` carrier.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [saved : (& r i64) (& r (deref x))]
      [items : (Array (& r i64) 1) (array saved)]
      (for [r : (& r i64) items]
        ; Must fail: the arena `r` resets before the caller reads `b.value`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)