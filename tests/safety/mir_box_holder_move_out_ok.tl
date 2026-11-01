;: As `mir_box_holder_move_out_reject`, but the array grows after the moved
;: `&mut`'s last use (#8449).
(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [held : (Box (&mut xs i64)) (box (&mut (array-ref xs 0)))]
    [m : (&mut xs i64) (deref held)]
    (set! (deref m) 40)
    (__tl_array-push! xs 2)
    (+ (array-ref xs 0) (array-ref xs 1))))