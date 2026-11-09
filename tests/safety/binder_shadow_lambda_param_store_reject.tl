;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). Lambda parameter.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [f
        (lambda ([r : i64]) : unit
          (set! b.value local))]
      (f 1))))

(define (main) : i64
  0)