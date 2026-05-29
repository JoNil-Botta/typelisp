;;; SPEC safe-code contract: generated collection lengths reject invalid
;;; allocation through the bounds-check abort path.
(define (main) : i64
  (let
    [a : (Array i64) (make-array i64 -1)]
    (array-length a)))