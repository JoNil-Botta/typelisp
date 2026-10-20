;; In a body that binds a name spelled like a caller lifetime, a value read
;; through one signature reference stores into a field reached through a
;; `&mut` with another: region tags are compared as main compares them.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(defstruct Outer
  (:lifetimes t)
  (inner (RefBox t)))

(define (copy-inner [src : (& t (Outer t))] [dst : (&mut d (Outer t))]) : i64
  (begin
    (set! dst.inner src.inner)
    (let
      [t : i64 1]
      t)))

(define (main) : i64
  0)