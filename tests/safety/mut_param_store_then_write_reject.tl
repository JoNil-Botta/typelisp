;: A reborrow of `*p` stored into the caller's `*b` outlives the call, so a
;: later write through `p` in the same body aliases it (Rust's E0506; #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (field-then-write [b : (&mut (RefBox a))] [p : (&mut a i64)]) : unit
  (set! (deref b).value (& (deref p)))
  (set! (deref p) 5))

(define (main) : i64
  0)