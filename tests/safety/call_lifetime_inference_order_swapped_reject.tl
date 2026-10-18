;; Call inference fixes a lifetime an invariant argument names, also when that
;; argument comes first: a shorter-lived reference cannot be stored through a
;; call into a longer-lived box.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [m : (&mut r (RefBox t))] [v : (& t i64)]) : unit
  (set! m.value v))

; Must fail: `z` does not outlive the box's `a`.
(define (refill [rb : (&mut a (RefBox a))]) : unit
  (let
    [z : i64 0]
    (put rb (& z))))

(define (main) : i64
  0)