;; hello.tl — A simple TypeLisp program
(import stdlib.io)

(define (factorial [n : i64]) : i64
  (if (= n 0)
    1
    (* n (factorial (- n 1)))))

(define (main) : i64
  (let
    [result : i64 (factorial 5)]
    (begin
      (io.print-string "Hello, TypeLisp!\n")
      (io.print-string "factorial(5) = ")
      (io.print result)
      0)))