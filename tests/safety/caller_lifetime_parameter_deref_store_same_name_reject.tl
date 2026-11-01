;; Callee-owned storage cannot escape through a whole-struct store into a caller
;; lifetime with the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (store [a : i64] [b : (&mut a (RefBox a))]) : unit
  (set! (deref b) (RefBox (& a))))

(define (main) : i64
  0)