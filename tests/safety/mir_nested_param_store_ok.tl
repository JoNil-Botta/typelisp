;: As `mir_nested_param_store_then_grow_reject`, without the later growth: the
;: stored reference may outlive the call (#8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (keep
  [b : (&mut o (&mut i (RefBox a)))]
  [xs : (& a (__tl_dyn-array i64))]) : unit
  (set! (deref (deref b)).value (& (array-ref (deref xs) 0))))

(define (main) : i64
  42)