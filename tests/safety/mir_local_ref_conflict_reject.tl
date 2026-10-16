;: Writing the borrowed array directly while a local mutable reference to it
;: is still used later is a conflict.
(define (run [items : (__tl_dyn-array i64)]) : i64
  (let
    [r : (&mut items (__tl_dyn-array i64)) (&mut items)]
    (begin
      (__tl_array-push! items 2)
      (__tl_array-push! r 1)
      0)))

(define (main) : i64
  0)