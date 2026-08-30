(import stdlib.format)

(define (main) : i64
  (let
    [pointer : (Ptr i64) (ptr-null : (Ptr i64))]
    (begin
      (format.format "{:?}" pointer)
      42)))