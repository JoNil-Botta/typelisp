;: Reading the array while a mutable view of it is live is rejected.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 11 12 13)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 1 2)]
    [peek : i64 (array-ref items 1)]
    (begin
      (set! (array-ref view 0) 30)
      peek)))