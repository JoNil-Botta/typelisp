(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
    [halves : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
      (slice-split-at-mut view 2)]
    [left : (&mut items (Slice i64)) (tuple-ref halves 0)]
    [right : (&mut items (Slice i64)) (tuple-ref halves 1)]
    (+ (array-ref items 0) (+ (array-ref left 0) (array-ref right 0)))))