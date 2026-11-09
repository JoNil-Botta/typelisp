;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). The place is rooted in a call result.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct OwnBox
  (:lifetimes a)
  (value (in a (Box i64))))

(define (id [b : (&mut a (RefBox a))]) : (&mut a (RefBox a))
  b)

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      (set! (deref (id b)).value local))))

(define (main) : i64
  0)