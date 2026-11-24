(define (main) : i64
  (let
    [pair : (Tuple (-> i64 i64) i64)
      (with-scratch
        (let
          [x : i64 42]
          (tuple
            (lambda ([y : i64]) : i64
              (+ x y))
            x)))]
    ((tuple-ref pair 0) (tuple-ref pair 1))))