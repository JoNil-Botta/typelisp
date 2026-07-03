;: Scalar continue is a zero-operand form.
(define (main) : i64
  (begin
    (while true
      (continue 1))
    0))