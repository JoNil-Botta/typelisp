;: A reference stored through a `&mut` reached via a parameter's referent is
;: the caller's: it stays live until the body returns, so growing the array
;: it points into afterwards conflicts (Rust E0502, #8449).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (keep-then-grow
  [b : (&mut o (&mut i (RefBox a)))]
  [xs : (&mut a (__tl_dyn-array i64))]) : unit
  (set! (deref (deref b)).value (& (array-ref (deref xs) 0)))
  (__tl_array-push! (deref xs) 5))

(define (main) : i64
  42)