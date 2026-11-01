(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [value : (& t i64)] [target : (&mut r (RefBox t))]) : i64
  (set! target.value value)
  (deref target.value))

(define (escape [target : (&mut a (RefBox a))]) : i64
  (let
    [local : i64 7]
    (put (& local) target)))

(define (main) : i64
  0)