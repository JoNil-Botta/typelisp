(define (read-refs [refs : (__tl_dyn-array (&mut items i64))]) : i64
  0)

;: Main's `loop_mut_borrow_stored_return_ok` before #8890: `refs` holds
;: borrows of the signature lifetime `items`, a universal region live at every
;: return, but `items` is a by-value parameter whose storage ends with the
;: call, so the pushed borrow outlives it. Rust: E0597 "argument requires that
;: `items` is borrowed for `'items`". Main accepted it; the loop rows now
;: borrow caller storage through `(&mut items ...)`.
(define (stored-return
  [run : bool]
  [items : (__tl_dyn-array i64)]
  [refs : (__tl_dyn-array (&mut items i64))]) : i64
  (begin
    (while run
      (begin
        ; Must fail: `items` dies when `stored-return` returns.
        (__tl_array-push! refs (&mut (array-ref items 0)))
        (return 0)))
    (begin
      (set! (array-ref items 0) 4)
      (+ (array-ref items 0) (read-refs refs)))))

(define (main) : i64
  0)