;; Callee-owned storage cannot escape into a caller lifetime with the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [a : i64] [b : (&mut a (RefBox a))]) : unit
  (set! b.value (& a)))

(define (main) : i64
  0)