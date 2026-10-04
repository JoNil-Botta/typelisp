;: A lane-uniform offset that can change between instances is not a constant
;: translation of the row-major domain. Reject it before scalar execution.
(define (main) : i64
  (let
    [offset : (Array i64 1) (make-array i64 1)]
    [out : (Array i64 8) (make-array i64 8)]
    (foreach
      ([y : i64 0 2] [x : i64 0 2])
      (begin
        (set!
          (array-ref out (+ (array-ref offset 0) (+ (* y 2) x)))
          (+ 1 (+ (* y 2) x)))
        (foreach-active
          [lane : i64]
          (set! (array-ref offset 0) (+ (array-ref offset 0) 1)))))
    0))