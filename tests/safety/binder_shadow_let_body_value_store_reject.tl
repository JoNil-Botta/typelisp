;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). The value is a let body.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      (set!
        b.value
        (let
          [z : i64 2]
          local)))))

(define (main) : i64
  0)