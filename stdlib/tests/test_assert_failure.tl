(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq 1 2 "stdlib test failure message")
    0))