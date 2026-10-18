;; A nested field of a resource spelled like a caller lifetime is the
;; resource's storage.
(defstruct RefBox
  (:lifetimes h)
  (value (& h i64)))

(defstruct Inner
  (x i64))

(defstruct Outer
  (inner Inner))

(define (drop-outer [o : Outer]) : unit
  unit)

(define (store [b : (&mut h (RefBox h))]) : unit
  (with
    ([h (Outer (Inner 3)) drop-outer])
    ; Must fail: `(& h.inner.x)` borrows the resource.
    (set! b.value (& h.inner.x))))

(define (main) : i64
  0)