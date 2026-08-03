;; A mutable parent and shared child cannot be used mutably through the parent
;; while the child remains live.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [parent : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
    [child : (& items (Slice i64)) (slice-view parent 1 2)]
    (begin
      (array-set! parent 0 99)
      (array-ref child 0))))