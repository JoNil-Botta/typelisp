;;; SPEC safe-code contract: invalid shift counts trap deterministically.
(define (main) : i64
  (begin
    (shl 1 -1)
    0))