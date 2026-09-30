;: A lane-value operand reads gang values; it does not call.
(define (twice [x : i64]) : i64
  (* x 2))

(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active [lane : i64] (set! total (lane-value (twice i)))))
      total)))