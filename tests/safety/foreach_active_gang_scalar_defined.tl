;: A uniform scalar bound inside the gang stays visible in the body.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (let
          [step : i64 2]
          (foreach-active [lane : i64] (set! total (+ total step)))))
      (if (= total 8)
        42
        1))))