;;; SPEC safe-code contract: dynamic-array bounds traps instead of performing
;;; invalid memory access.
(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 1)]
    (array-ref a 1)))