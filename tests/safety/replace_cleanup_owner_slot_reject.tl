;: A tuple slot reached through an active owner's field is still that owner's place.
(define (cleanup-pair [_pair : (Tuple i64 i64)]) : unit
  unit)

(defstruct CleanupHolder
  (:cleanup cleanup-holder)
  (pair (Tuple i64 i64) (:cleanup cleanup-pair)))

(define (main) : i64
  (with
    ([holder (CleanupHolder (tuple 7 8)) cleanup-holder])
    (replace! (tuple-ref holder.pair 0) 9)))