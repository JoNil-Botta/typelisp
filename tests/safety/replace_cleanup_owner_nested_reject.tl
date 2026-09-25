;: A nested element reached through an active owner's field is still that owner's place.
(define (cleanup-grid [_grid : (Array (Array i64 2) 2)]) : unit
  unit)

(defstruct CleanupHolder
  (:cleanup cleanup-holder)
  (grid (Array (Array i64 2) 2) (:cleanup cleanup-grid)))

(define (main) : i64
  (with
    ([holder (CleanupHolder (array (array 1 2) (array 3 4))) cleanup-holder])
    (replace! (array-ref (array-ref holder.grid 1) 0) 8)))