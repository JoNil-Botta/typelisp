;: Reinitialization is unavailable for explicit cleanup-owning element types.
(define (record-cleanup [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup record-cleanup)))

(define (take-token [items : (&mut items (Array CleanupToken 1))]) : CleanupToken
  (array-take! items 0))

(define (main) : i64
  42)