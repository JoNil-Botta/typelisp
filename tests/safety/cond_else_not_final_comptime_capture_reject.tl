(define (main) : i64
  (comptime
    (let
      [core-cond-else-must-be-final : i64 7]
      (cond [else 1] [false 2]))))