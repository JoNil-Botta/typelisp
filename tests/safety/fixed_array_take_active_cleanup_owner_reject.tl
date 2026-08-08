;: Taking through a field must not bypass its active owner's cleanup contract.
(define (cleanup-items [_items : (Array i64 1)]) : unit
  unit)

(defstruct CleanupHolder
  (:cleanup cleanup-holder)
  (items (Array i64 1) (:cleanup cleanup-items)))

(define (main) : i64
  (with
    ([holder (CleanupHolder (array 7)) cleanup-holder])
    (array-take! (struct-get holder items) 0)))