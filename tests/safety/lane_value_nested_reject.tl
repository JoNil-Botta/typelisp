;: A lane-value operand is already a gang expression.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active [lane : i64] (set! total (lane-value (lane-value i)))))
      total)))