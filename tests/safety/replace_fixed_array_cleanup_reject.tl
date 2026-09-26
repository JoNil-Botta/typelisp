;: An explicit cleanup-owning element cannot be detached by replacement.
(define (record-cleanup [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup record-cleanup)))

(define (swap-token
  [items : (&mut items (Array CleanupToken 1))]
  [next : CleanupToken]) : CleanupToken
  (replace! (array-ref items 0) next))

(define (main) : i64
  42)