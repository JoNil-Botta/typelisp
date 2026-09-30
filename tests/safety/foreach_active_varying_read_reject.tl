;: The body sees one lane at a time: a varying value needs lane-value.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active [lane : i64] (set! total (+ total i))))
      total)))