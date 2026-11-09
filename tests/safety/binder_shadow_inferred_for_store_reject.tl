;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). Inferred for item.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      [items : (Array i64 1) (array 1)]
      (for [r items]
        (set! b.value local)))))

(define (main) : i64
  0)