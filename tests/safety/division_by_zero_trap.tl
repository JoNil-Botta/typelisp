;;; SPEC safe-code contract: invalid integer division traps deterministically.
(define (main) : i64
  (begin
    (/ 1 0)
    0))