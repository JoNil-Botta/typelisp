;: lane-value is only valid inside a foreach-active body.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (let
          [x : i64 (lane-value i)]
          unit))
      total)))