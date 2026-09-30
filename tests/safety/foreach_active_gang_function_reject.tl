;: A function bound in the gang can capture its varying values, so the body
;: cannot call it: it would read the lane's index without lane-value.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (let
          [lane-index
            (lambda [] : i64
              i)]
          (foreach-active [lane : i64] (set! total (+ total (lane-index))))))
      total)))