(define (f [x : i64]) : i64
  (let
    [core-cond-else-must-be-final : i64 7]
    (cond [(< x 0) 1] [else 3] [(= x 0) 2])))

(define (main) : i64
  (f 1))