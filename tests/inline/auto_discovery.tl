(import stdlib.test)

(define (double [x : i64]) : i64
  (+ x x))

(test
  auto-discovery-basic
  (test.assert-i64-eq (double 21) 42 "inline auto-discovery should run"))

(test
  auto-discovery-second
  (test.assert-i64-eq (+ (double 10) 1) 21 "multiple inline tests should run"))
