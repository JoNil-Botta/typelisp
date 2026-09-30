;: continue is rejected inside a foreach-active body.
(define (main) : i64
  (begin
    (foreach
      ([i : i64 0 4])
      (foreach-active
        [lane : i64]
        (while false
          (continue))))
    0))