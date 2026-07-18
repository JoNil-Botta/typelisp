(import stdlib.iterator)
(import stdlib.vector)

(define (cleanup-item-value [_value : i64]) : unit
  unit)

(defstruct CleanupItem
  (:cleanup cleanup-cleanup-item)
  (value i64 (:cleanup cleanup-item-value)))

(import (vector.vector CleanupItem) as items)

(define (main) : unit
  (for [item : CleanupItem (items.new)] [index (iterator.range 0 1)] unit))