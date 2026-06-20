;: SPEC borrow contract: a borrow stored into an outer lifetime-bearing
;: aggregate from a loop body is conservatively live across loop iterations.
(define (read-items [items : (Array (& n i64))]) : i64
  1)

(define (main [n : i64] [items : (Array (& n i64))] [limit : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i limit)
        (begin
          (array-push! items (& n))
          (set! n 2)
          (set! i (+ i 1))))
      (read-items items))))