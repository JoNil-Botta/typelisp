;; Callee-owned storage cannot escape through a call that stores its argument
;; into a caller's box with the same lifetime name.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [v : (& t i64)] [m : (&mut r (RefBox t))]) : unit
  (set! m.value v))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (refill [a : i64] [rb : (&mut a (RefBox a))]) : unit
  (put (& a) rb))

(define (main) : i64
  0)