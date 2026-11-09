;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). An annotation under the binder cannot
;; relabel arena data.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct OwnBox
  (:lifetimes a)
  (value (in a (Box i64))))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      [z : (& r i64) local]
      (set! b.value z))))

(define (main) : i64
  0)