;; Callee-owned storage cannot escape into a caller lifetime with the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (identity [p : (& t i64)]) : (& t i64)
  p)

(define (store [a : i64] [b : (&mut a (RefBox a))]) : unit
  (set! b.value (identity (& a))))

(define (main) : i64
  0)