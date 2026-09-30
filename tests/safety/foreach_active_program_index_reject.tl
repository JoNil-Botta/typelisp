;: program-index is varying, so the body reads it through lane-value.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active [lane : i64] (set! total (program-index))))
      total)))