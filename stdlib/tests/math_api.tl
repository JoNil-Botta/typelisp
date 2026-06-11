(import "stdlib/math.tl")

(import "stdlib/test.tl")

(define (assert-i64-api) : unit
  (begin
    (assert-i64-eq (math-i64-abs -7) 7 "i64 abs negative")
    (assert-i64-eq (math-i64-abs 0) 0 "i64 abs zero")
    (assert-i64-eq (math-i64-abs 7) 7 "i64 abs positive")
    (assert-i64-eq
      (math-i64-abs -9223372036854775808)
      -9223372036854775808
      "i64 abs min unchanged")
    (assert-i64-eq
      (math-i64-abs-or -9223372036854775808 9223372036854775807)
      9223372036854775807
      "i64 abs-or min fallback")
    (assert-i64-eq (math-i64-min -3 9) -3 "i64 min")
    (assert-i64-eq (math-i64-max -3 9) 9 "i64 max")
    (assert-i64-eq (math-i64-clamp 5 0 10) 5 "i64 clamp inside")
    (assert-i64-eq (math-i64-clamp -1 0 10) 0 "i64 clamp low")
    (assert-i64-eq (math-i64-clamp 11 0 10) 10 "i64 clamp high")
    (assert-i64-eq (math-i64-clamp -1 10 0) 0 "i64 clamp reversed low")
    (assert-i64-eq (math-i64-clamp 11 10 0) 10 "i64 clamp reversed high")
    (assert-true (math-i64-negative? -1) "i64 negative")
    (assert-true (math-i64-zero? 0) "i64 zero")
    (assert-true (math-i64-positive? 1) "i64 positive")
    (assert-false (math-i64-positive? 0) "i64 positive false")))

(define (assert-f64-api) : unit
  (begin
    (assert-f64-eq (math-f64-abs -2.5) 2.5 "f64 abs negative")
    (assert-f64-eq (math-f64-abs 0.0) 0.0 "f64 abs zero")
    (assert-f64-eq (math-f64-abs 2.5) 2.5 "f64 abs positive")
    (assert-f64-eq (math-f64-min -3.5 9.25) -3.5 "f64 min")
    (assert-f64-eq (math-f64-max -3.5 9.25) 9.25 "f64 max")
    (assert-f64-eq (math-f64-clamp 5.5 0.0 10.0) 5.5 "f64 clamp inside")
    (assert-f64-eq (math-f64-clamp -1.0 0.0 10.0) 0.0 "f64 clamp low")
    (assert-f64-eq (math-f64-clamp 11.0 0.0 10.0) 10.0 "f64 clamp high")
    (assert-f64-eq
      (math-f64-clamp 11.0 10.0 0.0)
      10.0
      "f64 clamp reversed high")
    (assert-true (math-f64-negative? -0.5) "f64 negative")
    (assert-true (math-f64-zero? 0.0) "f64 zero")
    (assert-true (math-f64-positive? 0.5) "f64 positive")
    (assert-false (math-f64-negative? 0.0) "f64 negative false")))

(define (main) : i64
  (begin
    (assert-i64-api)
    (assert-f64-api)
    42))