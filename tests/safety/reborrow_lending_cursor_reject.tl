;: A result that borrows through `(&mut s (Cursor v))` lends: well-formedness
;: makes `v` outlive `s`, so the item keeps the cursor's `xs` borrow live
;: (Rust's implied bounds, #8449). Growing `xs` while the item is live
;: conflicts.
(defstruct Cursor
  (:lifetimes v)
  (slots (&mut v (__tl_dyn-array i64))))

(define (first [c : (&mut s (Cursor v))]) : (&mut s i64)
  (&mut (array-ref (deref (deref c).slots) 0)))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [c : (Cursor xs) (Cursor (&mut xs))]
    [x (first (&mut c))]
    (__tl_array-push! xs 2)
    (deref x)))