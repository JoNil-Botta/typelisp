(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(define (choose [x : i64]) : i64
  (begin
    (core/when (< x 0) (return 5))
    (core/unless (!= x 0) (return 7))
    42))

(define (main) : i64
  (+ (choose (- 0 1)) (+ (choose 0) (- (choose 9) 12))))