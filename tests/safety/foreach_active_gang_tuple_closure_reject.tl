;: A gang-local aggregate can hold a closure over the gang's varying values, so
;: the body cannot read it: calling the closure would read the lane's index
;: without lane-value.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (let
          [pair
            (tuple
              (lambda [] : i64
                i)
              1)]
          (foreach-active
            [lane : i64]
            (set! total (+ total ((tuple-ref pair 0)))))))
      total)))