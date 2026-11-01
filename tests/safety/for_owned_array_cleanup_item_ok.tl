;: Each cleanup-owning item of an owned array is discharged in the loop body.
(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64))

(define (main) : i64
  (let
    [sum : i64 0]
    (for [token : CleanupToken (array (CleanupToken 5) (CleanupToken 6))]
      (set! sum (+ sum token.value))
      (cleanup-token token))
    sum))