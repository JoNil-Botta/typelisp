;: Pointer formatting exposes an address through generated ptr->int and must
;: remain rejected unless the macro call is inside an unsafe context.
(import stdlib.format)

(define (main) : i64
  (let
    [pointer : (Ptr i64) (ptr-null : (Ptr i64))]
    (begin
      (format.format "{:p}" pointer)
      42)))