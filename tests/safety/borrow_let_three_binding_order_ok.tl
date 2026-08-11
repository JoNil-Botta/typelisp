;: A lending borrow used by one initializer ends before a later initializer
;: mutates its owner.
(define (take [_ref : (& n i64)]) : i64
  1)

(define (main [n : i64]) : i64
  (let
    [ref : (& n i64) (& n)]
    [used : i64 (take ref)]
    [written : i64
      (begin
        (set! n 2)
        40)]
    (+ used written 1)))