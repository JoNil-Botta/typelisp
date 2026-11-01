;: As `mir_by_value_param_store_then_grow_reject`, without the growth: the
;: stored reference may outlive the call (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a)))
  (xs (& a (__tl_dyn-array i64))))

(defstruct Two
  (a (__tl_dyn-array i64))
  (b (__tl_dyn-array i64)))

(define (keep [h : (Holder i a)]) : unit
  (set! (deref h.m).value (& (array-ref (deref h.xs) 0))))

(define (main) : i64
  (let
    [t : Two (Two (__tl_make-array i64 1) (__tl_make-array i64 1))]
    (set! (array-ref t.b 0) 42)
    (let
      [rb : (RefBox t) (RefBox (& (array-ref t.a 0)))]
      (keep (Holder (&mut rb) (& t.b)))
      (deref rb.value))))