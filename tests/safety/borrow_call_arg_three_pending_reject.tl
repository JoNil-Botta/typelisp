;: A nested write in an early argument cannot prune a lending borrow used by
;: a later third argument.
(define (use-three [_a : i64] [_b : i64] [_ref : (& n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (let
    [ref : (& n i64) (& n)]
    (use-three
      (begin
        (begin
          (set! n 2))
        0)
      1
      ref)))