;: An element read borrows the array shared: not while it is mutably
;: borrowed.
(define (grow [_items : (&mut items (__tl_dyn-array i64))]) : i64
  1)

(define (run [items : (__tl_dyn-array i64)]) : i64
  (let
    [r : (&mut items (__tl_dyn-array i64)) (&mut items)]
    [n : i64 (array-ref items 0)]
    (+ n (grow r))))

(define (main) : i64
  0)