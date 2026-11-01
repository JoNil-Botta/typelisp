;: A reference stored two `&mut` levels below a by-value holder lands in a
;: signature region, live to the end of the body: writing the borrowed `*h.x`
;: afterwards conflicts (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Outer
  (:lifetimes j a)
  (inner (&mut j (RefBox a))))

(defstruct Holder
  (:lifetimes i j a)
  (m (&mut i (Outer j a)))
  (x (&mut a i64)))

(define (keep-then-write [h : (Holder i j a)]) : unit
  (set! (deref (deref h.m).inner).value (& (deref h.x)))
  (set! (deref h.x) 9))

(define (main) : i64
  42)