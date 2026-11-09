;; An ordinary call cannot unify the caller lifetime with an arena region
;; through a binder of that name (#9751, D-C216).
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
      [r : i64 1]
      (write b local))))

(define (main) : i64
  0)