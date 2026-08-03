;; A shared Slice view blocks an exclusive view of the same fixed-array owner.
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [view : (& items (Slice i64)) (slice-view items 0 3)]
    [exclusive : (&mut items (Slice i64)) (slice-mut-view items 0 1)]
    (+ (array-ref view 0) (array-ref exclusive 0))))