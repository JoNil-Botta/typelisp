(import stdlib.test)

(define (main) : i64
  (test.assert-i64-eq 1 2 "stdlib test failure message")
  0)