(define (main) : i64
  (let
    [items : (Array i64 2) (array 1 2)]
    [view : (& items (Slice i64)) (slice-view items 0 2)]
    [halves (slice-split-at-mut view 1)]
    (array-length (tuple-ref halves 0))))