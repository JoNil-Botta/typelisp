;; A value trap precedes the final array-store bounds check.
(define (main) : i64
  (let
    [a : (Array i64 1) (array 0)]
    (set! (array-ref a 1) (shl (cast 1 : i64) -1))
    0))