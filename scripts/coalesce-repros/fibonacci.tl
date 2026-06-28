(import "stdlib/io.tl")

(define (main) : i64
  (let
    [a : i64 1]
    [b : i64 1]
    [i : i64 0]
    (begin
      (while (< i 20)
        (begin
          (let
            [t : i64 (+ a b)]
            (begin
              (set! a b)
              (set! b t)))
          (set! i (+ i 1))))
      (print b)
      0)))