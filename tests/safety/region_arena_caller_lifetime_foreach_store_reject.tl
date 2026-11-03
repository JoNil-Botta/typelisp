;; Rejected at entry: the arena is named like the caller lifetime `r` inside an
;; SPMD `foreach`, so the form fails with the collision diagnostic and the arena
;; must be renamed (#9593, D-C121). It was the review witness for arena data
;; stored into the caller's struct from SPMD code.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (foreach
    ([i : i64 0 1])
    (with-arena
      r
      (let
        [x : (Box i64) (box 5)]
        ; Must fail: the arena `r` resets before the caller reads `b.value`.
        (set! b.value (& (deref x)))))))

(define (main) : i64
  0)