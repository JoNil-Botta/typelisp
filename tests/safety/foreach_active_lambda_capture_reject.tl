;: A lambda in the body cannot capture a hidden varying binding.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (foreach-active
          [lane : i64]
          (set!
            total
            ((lambda [] : i64
                i)))))
      total)))