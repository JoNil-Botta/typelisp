(define (slice-split-at [x : i64] [y : i64]) : i64
  (+ x y))

(define (slice-split-at-mut [x : i64] [y : i64]) : i64
  (- x y))

(define (main) : i64
  (+ (slice-split-at 20 21) (slice-split-at-mut 2 1)))