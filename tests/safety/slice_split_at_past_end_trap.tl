(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 2)]
    [halves : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
      (slice-split-at-mut view 3)]
    (array-length (tuple-ref halves 0))))