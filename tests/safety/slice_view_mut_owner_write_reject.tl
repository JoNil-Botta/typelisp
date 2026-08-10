;; A live mutable Slice view blocks direct writes through its owner.
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 3)]
    (begin
      (set! (array-ref items 0) 99)
      (array-ref view 0))))