;: SPEC borrow contract: a borrow stored into outer boxed storage from a loop
;: body is conservatively live across loop iterations.
(define (read-cell [cell : (Box (& n i64))]) : i64
  1)

(define (main [limit : i64]) : i64
  (let
    [m : i64 0]
    [n : i64 1]
    [cell : (Box (& n i64)) (box (& m))]
    [i : i64 0]
    (begin
      (while (< i limit)
        (begin
          (set! (deref cell) (& n))
          (set! n 2)
          (set! i (+ i 1))))
      (read-cell cell))))