;; A mutable parent and mutable child remain exclusive even for a read through
;; the parent while the child remains live.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [parent : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
    [child : (&mut items (Slice i64)) (slice-mut-view parent 1 2)]
    (+ (array-ref parent 0) (array-ref child 0))))