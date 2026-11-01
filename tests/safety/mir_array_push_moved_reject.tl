;: A pushed element moves into the array: the binding cannot be used again.
(define (run [items : (&mut items (__tl_dyn-array (__tl_dyn-array i64)))]) : i64
  (let
    [name : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (__tl_array-push! items name)
      (array-length name))))

(define (main) : i64
  0)