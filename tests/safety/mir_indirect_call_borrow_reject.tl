;: A function value's mutable reference operand conflicts with a live borrow.
(define (bump! [items : (&mut items (__tl_dyn-array i64))]) : unit
  (set! (array-ref items 0) (+ (array-ref items 0) 1)))

(define (run [f : (-> (&mut a (__tl_dyn-array i64)) unit)]) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [view : (& items (__tl_dyn-array i64)) (& items)]
    (begin
      (f (&mut items))
      (array-ref view 0))))

(define (main) : i64
  (run bump!))