;: A reference to an element, read back out of a box, keeps the element's
;: loan: growing the array while it is used later would leave it pointing into
;: the replaced buffer (Rust E0502, #8449).
(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [held : (Box (& xs i64)) (box (& (array-ref xs 0)))]
    [r : (& xs i64) (deref held)]
    (__tl_array-push! xs 2)
    (deref r)))