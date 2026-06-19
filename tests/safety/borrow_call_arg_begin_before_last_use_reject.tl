(define (use-two [_value : i64] [_ref : (& n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (let
    [ref : (& n i64) (& n)]
    (use-two
      (begin
        (set! n 2)
        0)
      ref)))