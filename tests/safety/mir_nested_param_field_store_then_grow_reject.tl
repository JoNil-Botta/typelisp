;: As `mir_nested_param_store_then_grow_reject`, with the `&mut` in a field of
;: the parameter's referent (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Holder
  (:lifetimes i a)
  (m (&mut i (RefBox a))))

(define (keep-then-grow
  [h : (&mut o (Holder i a))]
  [xs : (&mut a (__tl_dyn-array i64))]) : unit
  (set! (deref (deref h).m).value (& (array-ref (deref xs) 0)))
  (__tl_array-push! (deref xs) 5))

(define (main) : i64
  42)