(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

;: A mutable borrow stored on a function-returning path cannot reach either the
;: loop backedge or the zero-trip successor. The borrowed `items` is caller
;: storage: a borrow of a by-value parameter stored under the signature
;: lifetime `items` would outlive the call (#8890).
(define (stored-return
  [run : bool]
  [items : (&mut items (__tl_dyn-array i64))]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (begin
        (__tl_array-push! refs (&mut (array-ref items 0)))
        (return 0)))
    (begin
      (set! (array-ref items 0) 4)
      (+ (array-ref items 0) (read-refs refs)))))

(define (main) : i64
  0)