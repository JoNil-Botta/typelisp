;: A binder of a `box` pattern takes the loans the box contents hold, as a part
;: moved out of the box does: `m` keeps `xs` borrowed, so the push (which may
;: move the buffer) conflicts. Main rejects it; the graph had accepted it.
(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [held : (Box (&mut xs i64)) (box (&mut (array-ref xs 0)))]
    (match held
      [(box m)
        (begin
          (__tl_array-push! xs 2)
          (deref m))])))