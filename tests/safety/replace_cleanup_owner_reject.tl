;: replace! cannot detach a value from an active explicit-cleanup owner.
(define (cleanup-items [_items : (Array i64 1)]) : unit
  unit)

(defstruct CleanupHolder
  (:cleanup cleanup-holder)
  (items (Array i64 1) (:cleanup cleanup-items)))

(define (main) : i64
  (with
    ([holder (CleanupHolder (array 7)) cleanup-holder])
    (begin
      (replace! holder.items (array 8))
      42)))