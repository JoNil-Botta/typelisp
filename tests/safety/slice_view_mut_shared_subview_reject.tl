;; A mutable Slice view blocks a shared subview of the same owner.
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 3)]
    [shared : (& items (Slice i64)) (slice-view items 0 1)]
    (+ (array-ref view 0) (array-ref shared 0))))