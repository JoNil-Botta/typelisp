(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

;: A break-path mutable borrow reaches the post-loop join. Its stored reference
;: keeps the exact element exclusively borrowed while `refs` remains live.
(define (bad
  [run : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (begin
        (array-push! refs (&mut (array-ref items 0)))
        (break)))
    (begin
      (set! (array-ref items 0) 4)
      (+ (array-ref items 0) (read-refs refs)))))