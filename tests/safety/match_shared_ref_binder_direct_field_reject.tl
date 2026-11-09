;; A `&`-typed field reached through a `&mut` parameter without a match (#9753).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(defstruct Outer
  (h (& program Holder))
  (k (Box i64)))

(define (write [r : (&mut r Outer)]) : i64
  (set! (deref r.h.b) 1)
  0)

(define (main) : i64
  0)