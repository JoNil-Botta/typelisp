;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). An array element through a mutable reference.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (Array (& r i64) 1))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      (set! (array-ref (deref b) 0) local))))

(define (main) : i64
  0)