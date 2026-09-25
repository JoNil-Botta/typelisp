;: An element reached through an active owner's field is still that owner's place.
(define (cleanup-items [_items : (Array i64 1)]) : unit
  unit)

(defstruct CleanupHolder
  (:cleanup cleanup-holder)
  (items (Array i64 1) (:cleanup cleanup-items)))

(define (main) : i64
  (with
    ([holder (CleanupHolder (array 7)) cleanup-holder])
    (replace! (array-ref holder.items 0) 8)))