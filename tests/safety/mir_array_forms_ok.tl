;: Array and raw storage forms under the ownership MIR: pushes and element
;: writes borrow their receiver exclusively for the form, reads borrow it
;: shared, and a Copy global read is a plain value.
(define base : i64
  2)

(define (fill [items : (&mut items (__tl_dyn-array i64))] [count : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (begin
        (__tl_array-push! items (* index base))
        (set! index (+ index 1))))))

(define (run) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [names : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 1)]
    (begin
      (fill (&mut items) 4)
      (set! (array-ref items 0) (array-ref items 3))
      (set! (array-ref names 0) (__tl_make-array i64 1))
      (+
        (array-ref items 0)
        (array-length items)
        (* base 13)
        (array-ref items 2)
        (array-length (array-ref names 0))
        (array-length names)))))

(define (main) : i64
  (run))