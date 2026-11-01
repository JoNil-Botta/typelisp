;: A `&mut` moved out of a by-value box parameter still reaches caller memory
;: (#8449, Rust E0502).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (keep-then-grow
  [b : (Box (&mut i (RefBox a)))]
  [xs : (&mut a (__tl_dyn-array i64))]) : unit
  (let
    [m : (&mut i (RefBox a)) (deref b)]
    (set! (deref m).value (& (array-ref (deref xs) 0)))
    (__tl_array-push! (deref xs) 5)))

(define (main) : i64
  42)