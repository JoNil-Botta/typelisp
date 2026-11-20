;; load-CSE: two loads in one loop body around a set! of v.
;; Expected exit 45 at --opt-level 0 (opt1 and opt2 exit 42 and 42 until the queued fix lands).
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
      (set!
        acc
        (+
          acc
          (unsafe
            (ptr-read p))))
      (set! i (+ i 1)))
    (+ 30 acc)))