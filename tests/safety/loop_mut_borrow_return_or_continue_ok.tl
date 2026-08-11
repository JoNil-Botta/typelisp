(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

;: Only the returning arm creates the mutable borrow; the continue arm reaches
;: the backedge without it.
(define (borrow-return-or-continue
  [run : bool]
  [take : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (if take
        (begin
          (array-push! refs (&mut (array-ref items 0)))
          (return 0))
        (continue)))
    (begin
      (set! (array-ref items 0) 4)
      (+ (array-ref items 0) (read-refs refs)))))

(define (main) : i64
  0)