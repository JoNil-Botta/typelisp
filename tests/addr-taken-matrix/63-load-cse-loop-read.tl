;; load-CSE: a load at the top of a loop after a set! at the bottom.
;; Expected exit 45 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 3)
      (set!
        acc
        (+
          acc
          (unsafe
            (ptr-read p))))
      (set! v (+ v 1))
      (set! i (+ i 1)))
    (+ 39 acc)))