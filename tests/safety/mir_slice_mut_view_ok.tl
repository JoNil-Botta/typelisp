;: A mutable slice view writes through to its array.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 11 12 13)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 1 2)]
    (begin
      (set! (array-ref view 0) 30)
      (+ (array-ref items 1) 12))))