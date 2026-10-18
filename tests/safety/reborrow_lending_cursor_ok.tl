;: A lent item releases the cursor's borrow after its last use (#8449).
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
    [y : i64 (deref x)]
    (__tl_array-push! xs 2)
    (+ y 42)))