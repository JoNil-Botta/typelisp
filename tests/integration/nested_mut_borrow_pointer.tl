(defstruct Inner
  (p (Ptr i64)))

(defstruct Outer
  (inner Inner)
  (tail i64))

(define (change! [p : (&mut p (Ptr i64))]) : unit
  (set!
    (deref p)
    (unsafe
      (int->ptr (cast 5 : u64) : (Ptr i64)))))

(define (main) : i64
  (let
    [s : Outer (Outer (Inner (ptr-null : (Ptr i64))) 20)]
    (change! (&mut s.inner.p))
    (cast
      (unsafe
        (ptr->int s.inner.p))
      : i64)))