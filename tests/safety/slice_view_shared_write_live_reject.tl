;; A live shared Slice view blocks writes through its fixed-array owner.
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [view : (& items (Slice i64)) (slice-view items 0 3)]
    (begin
      (set! (array-ref items 0) 99)
      (array-ref view 0))))