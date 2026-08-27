;; A live shared Slice view keeps its dynamic-array owner from being moved.
(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (begin
      (set! (array-ref items 0) 10)
      (let
        [view : (& items (Slice i64)) (slice-view items 0 1)]
        [moved : (__tl_dyn-array i64) items]
        (+ (array-ref view 0) (array-ref moved 0))))))