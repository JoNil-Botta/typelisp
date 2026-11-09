;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). An ann form cannot relabel arena data.
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
      (set! b.value (ann local : (& r i64))))))

(define (main) : i64
  0)