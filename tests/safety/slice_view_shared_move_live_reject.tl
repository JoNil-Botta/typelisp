;; A live shared Slice view keeps its fixed-array owner from being moved.
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [view : (& items (Slice i64)) (slice-view items 0 3)]
    [moved : (Array i64 3) items]
    (+ (array-ref view 0) (array-ref moved 0))))