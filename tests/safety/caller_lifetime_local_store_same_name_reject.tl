;; Callee-owned storage cannot escape into a caller lifetime with the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut a (RefBox a))]) : unit
  (let
    [a : i64 5]
    (set! b.value (& a))))

(define (main) : i64
  0)