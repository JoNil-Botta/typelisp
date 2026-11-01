;; Moving one field out of a nested tuple place consumes only that field: the
;; Copy sibling read before and after the move stays live.
(define (nested-place-score [value : (Tuple (Tuple i64 (Box i64)) bool)]) : i64
  (let
    [before : i64 (tuple-ref (tuple-ref value 0) 0)]
    [owned : (Box i64) (tuple-ref (tuple-ref value 0) 1)]
    ;; Acquiring the Box consumes only that field; the Copy sibling survives.
    [after : i64 (tuple-ref (tuple-ref value 0) 0)]
    (if (tuple-ref value 1)
      (+ (+ before after) (deref owned))
      0)))

(define (main) : i64
  (let
    [t : (Tuple bool i64) (tuple true 42)]
    (begin
      (unless (and (tuple-ref t 0) (= (tuple-ref t 1) 42)) (return 1))
      (nested-place-score (tuple (tuple 10 (box 22)) true)))))