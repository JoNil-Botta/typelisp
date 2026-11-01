;: A stored element moves into its slot: the binding cannot be used again.
(define (run [items : (__tl_dyn-array (__tl_dyn-array i64))]) : i64
  (let
    [name : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref items 0) name)
      (array-length name))))

(define (main) : i64
  0)