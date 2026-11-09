;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). Two nested binders of the same name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [r : i64 1]
      (let
        [r : i64 2]
        [z : (& r i64) local]
        (set! b.value z)))))

(define (main) : i64
  0)