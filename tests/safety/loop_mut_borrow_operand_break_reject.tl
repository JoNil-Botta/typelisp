(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

(define (keep [n : i64]) : unit
  unit)

;: A break nested in a call argument leaves the loop with the mutable borrow
;: stored before it, so the element stays borrowed after the loop (#8671).
(define (bad
  [run : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (keep
        (if run
          (begin
            (__tl_array-push! refs (&mut (array-ref items 0)))
            (break))
          1))
      (break))
    (begin
      (set! (array-ref items 0) 4)
      (+ (array-ref items 0) (read-refs refs)))))

(define (main) : i64
  0)