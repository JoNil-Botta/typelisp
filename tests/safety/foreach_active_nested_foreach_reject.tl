;: A foreach-active body cannot open another gang.
(define (main) : i64
  (begin
    (foreach
      ([i : i64 0 4])
      (foreach-active [lane : i64] (foreach ([j : i64 0 2]) unit)))
    0))