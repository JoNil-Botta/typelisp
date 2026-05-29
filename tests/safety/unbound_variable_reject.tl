;;; SPEC safe-code contract: safe code cannot read a place that has no valid
;;; initialized binding.
(define (main) : i64
  missing)