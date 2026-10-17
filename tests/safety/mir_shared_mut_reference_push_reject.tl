;: A `&mut` reached through a `&` grants shared access only: growing the array
;: through it is rejected (Rust E0596, #8449).
(define (grow [r : (& o (&mut i (__tl_dyn-array i64)))]) : unit
  (__tl_array-push! (deref (deref r)) 9))

(define (main) : i64
  42)