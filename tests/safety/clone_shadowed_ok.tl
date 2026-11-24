;; #8232/#7073: `clone` is an ordinary identifier when defined in scope.
(define (clone) : i64
  40)

(define (add-shadow [clone : i64]) : i64
  (+ clone 2))

(define (main) : i64
  (add-shadow (clone)))