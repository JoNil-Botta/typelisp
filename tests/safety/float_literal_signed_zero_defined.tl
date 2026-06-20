;; Signed zero is a finite source float constant for both f64 and contextual f32.
(define (main) : i64
  (let
    [a : f64 -0.0]
    [b : f32 -0.0]
    (if (= a 0.0)
      (if (= b 0.0)
        42
        1)
      2)))