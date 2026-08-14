;; A shared dynamic-array Slice blocks growth that may reallocate its owner.
(import stdlib.array)

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    (begin
      (set! (array-ref items 0) 10)
      (let
        [view : (& items (Slice i64)) (slice-view items 0 1)]
        (begin
          (__tl_array-push! items 20)
          (array-ref view 0))))))