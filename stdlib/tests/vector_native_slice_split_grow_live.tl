(import stdlib.vector)
(import (stdlib.vector.vector i64) as vec)

; A mutable split preserves the Vec owner borrow, so growth cannot replace the
; backing allocation while either disjoint half remains live.
(define (main) : i64
  (let
    [items : vec.Vec (vec.new)]
    (begin
      (vec.push! items 10)
      (vec.push! items 20)
      (let
        [view : (&mut items (Slice i64)) (vec.view-mut (&mut items))]
        [halves : (Tuple (&mut items (Slice i64)) (&mut items (Slice i64)))
          (slice-split-at-mut view 1)]
        [left : (&mut items (Slice i64)) (tuple-ref halves 0)]
        [right : (&mut items (Slice i64)) (tuple-ref halves 1)]
        (begin
          (vec.push! items 30)
          (+ (array-ref left 0) (array-ref right 0)))))))