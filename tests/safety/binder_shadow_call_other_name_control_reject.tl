;; Control for #9751: a binder of another name keeps the argument 1 mismatch.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (write [b : (&mut a (RefBox a))] [v : (& a i64)]) : unit
  (set! b.value v))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [other : i64 1]
      (write b local))))

(define (main) : i64
  0)