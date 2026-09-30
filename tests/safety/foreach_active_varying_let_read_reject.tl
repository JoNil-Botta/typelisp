;: A varying gang local is hidden from the body just like the index.
(define (main) : i64
  (let
    [total : i64 0]
    (begin
      (foreach
        ([i : i64 0 4])
        (let
          [twice : i64 (* i 2)]
          (foreach-active [lane : i64] (set! total (+ total twice)))))
      total)))