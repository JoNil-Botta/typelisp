;; A `&mut` held in a struct behind `&` grants shared access only, so a view
;; read through it is behind the shared reference (#9646).
(defstruct Holder
  (b (Box i64)))

(defstruct Link
  (:lifetimes p)
  (h (&mut p Holder)))

(define (sink [b : (Box i64)]) : i64
  (deref b))

(define (take [r : (& r (Link p))]) : i64
  (let
    [b : (Box i64) r.h.b]
    (sink b)))

(define (main) : i64
  0)