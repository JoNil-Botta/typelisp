(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector CleanupToken) as tokens)

(define (stale-view-length [iter : (& iter tokens.IntoIter)]) : i64
  (array-length (tokens.view (& iter.vec))))

(define (main) : i64
  (with
    ([iter (tokens.into-iterator (tokens.new)) tokens.cleanup-into-iter])
    (stale-view-length (& iter))))