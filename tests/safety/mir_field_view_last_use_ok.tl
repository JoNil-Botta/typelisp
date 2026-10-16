;: A shared field reborrow ends at its last use, permitting a later mutation.
(defstruct Holder
  (items (__tl_dyn-array i64))
  (count i64))

(define (grow [items : (&mut items (__tl_dyn-array i64))]) : i64
  (set! (array-ref items 0) 40)
  (array-ref items 0))

(define (peek [items : (& items (__tl_dyn-array i64))]) : i64
  (array-ref items 0))

(define (run [h : (&mut h Holder)]) : i64
  (let
    [view : (& h (__tl_dyn-array i64)) (& h.items)]
    [n : i64 (peek view)]
    (+ n (grow (&mut h.items)))))

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (set! (array-ref items 0) 2)
    (let
      [holder : Holder (Holder items 0)]
      (run (&mut holder)))))