;: A function from outside the foreach is uniform, so the body may call it.
(define (main) : i64
  (let
    [total : i64 0]
    [step
      (lambda [] : i64
        2)]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active [lane : i64] (set! total (+ total (step)))))
      (if (= total 8)
        42
        1))))