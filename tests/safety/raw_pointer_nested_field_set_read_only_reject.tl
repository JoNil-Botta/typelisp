(defstruct Inner
  (a i64)
  (b i64))

(defstruct Outer
  (inner Inner)
  (n i64))

(define (write-a [p : (Ptr Outer)]) : unit
  (unsafe
    (set! (deref p).inner.a 10)))

(define (main) : i64
  0)