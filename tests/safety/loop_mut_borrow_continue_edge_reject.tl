(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

;: The mutable borrow is established before a reachable continue edge and can
;: therefore overlap the next iteration.
(define (bad
  [run : bool]
  [leave : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (begin
        (array-push! refs (&mut (array-ref items 0)))
        (if leave
          (return 0)
          (continue))))
    (begin
      (set! (array-ref items 0) 4)
      (+ (array-ref items 0) (read-refs refs)))))