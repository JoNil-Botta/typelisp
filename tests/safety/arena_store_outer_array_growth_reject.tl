;; Growing an outer DynArray inside with-arena reallocates its buffer in the
;; scoped arena, whatever its element type: here i64, so no element store
;; could catch it (#9806 family).
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array 1 2)]
    (begin
      (with-arena r (__tl_array-push! items 3))
      (if (= (array-ref items 2) 3)
        42
        7))))