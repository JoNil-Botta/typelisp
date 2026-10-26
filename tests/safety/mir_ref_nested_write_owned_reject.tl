;: The callee would observe the array the nested assignment replaced.
(define (use-two [items : (& v (__tl_dyn-array i64))] [value : i64]) : i64
  (+ value (array-ref items 0)))

(define (fill [n : i64]) : (__tl_dyn-array i64)
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (begin
      (__tl_array-push! items n)
      items)))

(define (main) : i64
  (let
    [v : (__tl_dyn-array i64) (fill 7)]
    [ref : (& v (__tl_dyn-array i64)) (& v)]
    (use-two
      ref
      (begin
        (set! v (fill 9))
        0))))