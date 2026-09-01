;: Generated deques reject cleanup-owning elements before emitting storage.
(import stdlib.queue)

(define (queue-cleanup-element-close [_value : i64]) : unit
  unit)

(defstruct QueueCleanupElement
  (:cleanup queue-cleanup-element-cleanup)
  (value i64 (:cleanup queue-cleanup-element-close)))

(import (queue.deque QueueCleanupElement) as cleanup_queue)

(define (main) : i64
  0)