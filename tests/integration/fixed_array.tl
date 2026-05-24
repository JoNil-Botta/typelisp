(define (main) : i64
  (let ([a : (Array i64 3) (array 2 2 3)])
    (begin
      (array-set! a 1 40)
      (+ (array-ref a 0) (array-ref a 1)))))