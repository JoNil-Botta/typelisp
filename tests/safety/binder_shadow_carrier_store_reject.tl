;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). The binder carries the arena reference.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [r : (& s i64) (& s (deref x))]
      (set! b.value r))))

(define (main) : i64
  0)