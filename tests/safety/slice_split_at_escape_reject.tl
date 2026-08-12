(define (bad [outer : (&mut outer (Slice i64))]) : (Tuple
    (&mut outer (Slice i64))
    (&mut outer (Slice i64)))
  (let
    [items : (Array i64 2) (array 1 2)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 2)]
    (slice-split-at-mut view 1)))

(define (main) : i64
  (let
    [items : (Array i64 1) (array 0)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 1)]
    [halves (bad view)]
    (array-length (tuple-ref halves 0))))