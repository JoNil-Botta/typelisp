;; The halves of a split hold the source's loan: writing the array while a
;; half is still used is rejected.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [view : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
    [halves : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
      (slice-split-at-mut view 2)]
    [left : (&mut items (Slice i64)) (tuple-ref halves 0)]
    (begin
      (set! (array-ref items 0) 5)
      (array-ref left 0))))