;: `for` over a fixed array moves each cleanup-owning item into its binding,
;: which must then be discharged like any `let` owner (SPEC 4.7.1). Main
;: accepted this, and its lowering never ran the items' cleanup.
(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64))

(define (main) : i64
  (let
    [sum : i64 0]
    (for [token : CleanupToken (array (CleanupToken 5) (CleanupToken 6))]
      (set! sum (+ sum 1)))
    sum))