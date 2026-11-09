;; A value binder spelled like the caller lifetime does not let arena data
;; reach caller storage (#9609). Match binder.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (None)
  (Some i64))

(define (store [b : (&mut r (RefBox r))] [o : Opt]) : unit
  (with-arena
    s
    (let
      [x : (Box i64) (box 5)]
      [local : (& s i64) (& s (deref x))]
      (match o
        [(Some r) (set! b.value local)]
        [(None) unit]))))

(define (main) : i64
  0)