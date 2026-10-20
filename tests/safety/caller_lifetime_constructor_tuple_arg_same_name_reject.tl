;; Callee-owned storage cannot escape through a tuple argument of a constructor
;; into a caller lifetime with the same name.
(defstruct PairBox
  (:lifetimes a)
  (pair (Tuple (& a i64) i64)))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (store [a : i64] [b : (&mut a (PairBox a))]) : unit
  (set! (deref b) (PairBox (tuple (& a) 1))))

(define (main) : i64
  0)