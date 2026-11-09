;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). A dynamic array push.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct OwnBox
  (:lifetimes a)
  (value (in a (Box i64))))

(define (store [b : (&mut r (__tl_dyn-array (& r i64)))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      (__tl_array-push! (deref b) local))))

(define (main) : i64
  0)