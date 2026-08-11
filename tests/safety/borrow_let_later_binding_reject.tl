;: A nested write in one let initializer cannot prune a lending borrow used by
;: a later initializer.
(define (take [_ref : (& n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (let
    [ref : (& n i64) (& n)]
    [written : i64
      (begin
        (set! n 2)
        0)]
    [used : i64 (take ref)]
    (+ written used)))