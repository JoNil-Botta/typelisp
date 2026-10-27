;; A nested lambda duplicates the first lambda's body and capture layout.
(define (main) : i64
  (let
    [x : i64 42]
    [f
      (lambda () : i64
        x)]
    [g
      (lambda () : i64
        (let
          [inner
            (lambda () : i64
              x)]
          (inner)))]
    (if (and (= (f) 42) (= (g) 42))
      42
      1)))