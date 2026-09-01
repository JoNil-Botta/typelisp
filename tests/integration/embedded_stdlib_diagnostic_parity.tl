;; Source-root and embedded-TLCI stdlib modes must reject this generated family
;; identically, at the request, without materializing partial declarations.
(import stdlib.queue)

(define (record-cleanup [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup record-cleanup)))

(import (queue.deque CleanupToken) as tokens)