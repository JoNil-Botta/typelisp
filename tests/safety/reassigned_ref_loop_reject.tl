;: A reassignment inside a loop that may not run leaves the first loan reaching
;: the loop exit (#8449).
(defstruct P
  (l i64)
  (r i64))

(define (read [view : (& v i64)]) : i64
  (deref view))

(define (walk [n : i64]) : i64
  (let
    [p : P (P 1 2)]
    [view : (& p i64) (& p.l)]
    [i : i64 0]
    (while (< i n)
      (set! view (& p.r))
      (set! i (+ i 1)))
    (set! p.l 5)
    (read view)))

(define (main) : i64
  (walk 0))