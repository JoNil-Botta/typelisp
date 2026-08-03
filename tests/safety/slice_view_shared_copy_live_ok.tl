;; Copying a structurally Copyable fixed array remains valid while its shared
;; Slice view is live.
(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 30)]
    [view : (& items (Slice i64)) (slice-view items 0 3)]
    [copied : (Array i64 3) items]
    (+ (array-ref view 0) (array-ref copied 0))))