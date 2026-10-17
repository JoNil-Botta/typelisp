;: A `&mut` moved out of a box holding it keeps the loan the box held:
;: growing the array while it is used later would leave it pointing into the
;: replaced buffer (Rust E0499, #8449).
(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [held : (Box (&mut xs i64)) (box (&mut (array-ref xs 0)))]
    [m : (&mut xs i64) (deref held)]
    (__tl_array-push! xs 2)
    (deref m)))