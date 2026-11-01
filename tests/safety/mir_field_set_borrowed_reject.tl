;: A field cannot be stored while a reference into it is still used.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (run [holder : Holder]) : i64
  (let
    [items : (& holder (__tl_dyn-array i64)) (& holder.items)]
    (begin
      (set! holder.items (__tl_make-array i64 0))
      (array-length items))))

(define (main) : i64
  0)