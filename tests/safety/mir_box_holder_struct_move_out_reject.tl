;: As `mir_box_holder_move_out_reject`, moving a struct holding the `&mut` out
;: of the box (#8449).
(defstruct RefMut
  (:lifetimes a)
  (r (&mut a i64)))

(define (main) : i64
  (let
    [xs : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [held : (Box (RefMut xs)) (box (RefMut (&mut (array-ref xs 0))))]
    [m : (RefMut xs) (deref held)]
    (__tl_array-push! xs 2)
    (deref m.r)))