;: Storing the same owned value into every slot moves it on the first
;: iteration.
(define (fill
  [items : (&mut items (__tl_dyn-array (__tl_dyn-array i64)))]
  [value : (__tl_dyn-array i64)]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length items))
      (begin
        (set! (array-ref items index) value)
        (set! index (+ index 1))))))

(define (main) : i64
  0)