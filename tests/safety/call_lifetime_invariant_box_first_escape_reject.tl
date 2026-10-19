(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put-swapped [target : (&mut r (RefBox t))] [value : (& t i64)]) : i64
  (set! target.value value)
  (deref target.value))

(define (escape [target : (&mut a (RefBox a))]) : i64
  (let
    [local : i64 7]
    (put-swapped target (& local))))

(define (main) : i64
  0)