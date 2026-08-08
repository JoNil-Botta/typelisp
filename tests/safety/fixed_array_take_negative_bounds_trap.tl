;: Negative fixed-array take indexes use the ordinary checked-array trap.
(define (main) : i64
  (let
    [items : (Array i64 1) (array 7)]
    (array-take! items -1)))