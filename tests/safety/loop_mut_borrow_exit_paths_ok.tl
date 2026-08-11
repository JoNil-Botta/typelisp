;: Body-local mutable borrows on return and break paths do not reach the loop
;: backedge. The zero-trip/break successor can read the owner normally.
(define (borrow-return [run : bool] [items : (__tl_dyn-array i64)]) : i64
  (begin
    (while run
      (let
        [slot : (&mut items i64) (&mut (array-ref items 0))]
        (return (deref slot))))
    (array-ref items 0)))

(define (borrow-break [run : bool] [items : (__tl_dyn-array i64)]) : i64
  (begin
    (while run
      (let
        [slot : (&mut items i64) (&mut (array-ref items 0))]
        (begin
          (set! (deref slot) 4)
          (break))))
    (array-ref items 0)))

(define (main) : i64
  0)