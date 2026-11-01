;: Moving move-only contents out of a box consumes the box.
(define (run [items : (Box (__tl_dyn-array i64))]) : i64
  (let
    [taken : (__tl_dyn-array i64) (deref items)]
    (+ (array-length taken) (array-length (deref items)))))

(define (main) : i64
  0)