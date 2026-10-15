;; Later mutation cannot make a boolean a valid integer operand.
(define (main) : i64
  (let
    [x : i64 1]
    (+
      x
      (begin
        (set! x 99)
        true))))