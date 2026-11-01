;: An array literal moves its elements in.
(define (run [items : (__tl_dyn-array i64)]) : i64
  (let
    [all : (Array (__tl_dyn-array i64) 1) (array items)]
    (array-length items)))

(define (main) : i64
  0)