;; load-CSE: v is set inside a loop that runs between the two loads.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (let
      [i : i64 0]
      (while (< i 2)
        (set! v 5)
        (set! i (+ i 1))))
    (+
      a
      (unsafe
        (ptr-read p)))))