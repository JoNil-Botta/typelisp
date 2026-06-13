(define (choose [x : i64]) : i64
  (begin
    (when (< x 0) (return 5))
    (unless (!= x 0) (return 7))
    42))

(define (main) : i64
  (+ (choose (- 0 1)) (+ (choose 0) (- (choose 9) 12))))