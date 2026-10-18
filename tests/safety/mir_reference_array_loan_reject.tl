;: An array holding a reference keeps that reference's loan alive.
(define (run [items : (__tl_dyn-array i64)]) : i64
  (let
    [view : (& items (__tl_dyn-array i64)) (& items)]
    [views : (Array (& items (__tl_dyn-array i64)) 1) (array view)]
    (begin
      (__tl_array-push! items 1)
      (let
        [first : (& items (__tl_dyn-array i64)) (array-ref views 0)]
        (array-length first)))))

(define (main) : i64
  0)