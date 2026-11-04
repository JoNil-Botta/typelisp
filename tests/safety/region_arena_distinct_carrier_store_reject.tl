;; Rejected at entry: the arena is named like the caller lifetime `r`, so the
;; form fails with the collision diagnostic and the arena must be renamed
;; (#9593, D-C121). It was the review witness for arena data carried out to
;; caller storage by a differently named carrier.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    r
    (let
      [x : (Box i64) (box 5)]
      [local : (& r i64) (& r (deref x))]
      ; Must fail: `local` borrows the arena, which resets before the caller
      ; reads `b.value`.
      (set! b.value local))))

(define (main) : i64
  0)