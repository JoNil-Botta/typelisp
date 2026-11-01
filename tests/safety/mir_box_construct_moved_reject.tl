;: Boxing a value moves it into the box.
(define (run [items : (__tl_dyn-array i64)]) : i64
  (let
    [boxed : (Box (__tl_dyn-array i64)) (box items)]
    (array-length items)))

(define (main) : i64
  0)