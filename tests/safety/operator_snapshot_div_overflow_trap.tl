;; Capturing the dividend must retain its overflow trap despite the RHS write.
(define (main) : i64
  (let
    [x : i8 (cast -128 : i8)]
    (cast
      (/
        x
        (begin
          (set! x (cast 0 : i8))
          (cast -1 : i8)))
      : i64)))