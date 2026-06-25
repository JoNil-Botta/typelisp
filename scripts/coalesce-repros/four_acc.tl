(import "stdlib/io.tl")

(define (main) : i64
  (let
    [a : i64 0]
    [b : i64 0]
    [c : i64 0]
    [d : i64 0]
    [i : i64 1]
    (begin
      (while (<= i 1000)
        (begin
          (set! a (+ a i))
          (set! b (+ b (* i 2)))
          (set! c (+ c (* i 3)))
          (set! d (+ d (* i 4)))
          (set! i (+ i 1))))
      (print (+ (+ a b) (+ c d)))
      0)))