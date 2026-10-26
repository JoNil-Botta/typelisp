;: A by-value parameter holding a `&mut` reaches caller memory: a reference
;: stored through it outlives the call, so growing the array it points into
;: afterwards conflicts (Rust E0502, #8449). Run, `rb.value` would read the
;: replaced buffer.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a)))
  (xs (&mut a (__tl_dyn-array i64))))

(define (keep-then-grow [h : (Holder i a)]) : unit
  (set! (deref h.m).value (& (array-ref (deref h.xs) 0)))
  (__tl_array-push! (deref h.xs) 5))

(define (main) : i64
  42)