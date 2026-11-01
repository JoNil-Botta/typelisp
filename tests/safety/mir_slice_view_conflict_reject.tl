;: Writing the array while a shared view of it is live is rejected.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 11 12 13)]
    [view : (& items (Slice i64)) (slice-view items 1 2)]
    (begin
      (set! (array-ref items 1) 19)
      (array-ref view 0))))