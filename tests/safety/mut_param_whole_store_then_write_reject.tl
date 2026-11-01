;: Storing a whole value holding a reborrow of `*p` into the caller's `*b`
;: keeps that loan until the body returns: writing through `p` afterwards is
;: rejected (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (whole-then-write [b : (&mut (RefBox a))] [p : (&mut a i64)]) : unit
  (set! (deref b) (RefBox (& (deref p))))
  (set! (deref p) 5))

(define (main) : i64
  0)