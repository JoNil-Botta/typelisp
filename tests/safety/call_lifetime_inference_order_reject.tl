;; Call inference fixes a lifetime an invariant argument names: a shorter-lived
;; reference cannot be stored through a call into a longer-lived box.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [v : (& t i64)] [m : (&mut r (RefBox t))]) : unit
  (set! m.value v))

; Must fail: `z` does not outlive the box's `a`.
(define (refill [rb : (&mut a (RefBox a))]) : unit
  (let
    [z : i64 0]
    (put (& z) rb)))

(define (main) : i64
  0)