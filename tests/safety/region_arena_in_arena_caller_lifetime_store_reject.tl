;; Rejected at entry: the arena is named like the caller lifetime `r`, inside an
;; `in-arena` selecting the caller's branded arena, so the form fails with the
;; collision diagnostic and the arena must be renamed (#9593, D-C121). It was
;; the review witness for arena data stored to the caller under an enclosing
;; `in-arena`.
(import stdlib.arena)

(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [home : (arena.Arena r)] [b : (&mut r (RefBox r))]) : unit
  (in-arena
    home
    (with-arena
      r
      (let
        [x : (Box i64) (box 5)]
        ; Must fail: `x` lives in the inner arena, not in `home`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)