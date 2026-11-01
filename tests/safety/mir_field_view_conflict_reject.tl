;: A view of a field read through a mutable reference is a shared reborrow:
;: the field cannot be mutably borrowed while the view is still used.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (grow [_items : (&mut items (__tl_dyn-array i64))]) : i64
  1)

(define (peek [_items : (& items (__tl_dyn-array i64))]) : i64
  2)

(define (run [h : (&mut h Holder)]) : i64
  (let
    [view : (__tl_dyn-array i64) h.items]
    [n : i64 (grow (&mut h.items))]
    (+ n (peek view))))

(define (main) : i64
  0)