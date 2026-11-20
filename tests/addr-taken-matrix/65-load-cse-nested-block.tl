;; load-CSE: the set! lives in a nested block between the two loads.
;; Expected exit 2 at --opt-level 0 (opt1 and opt2 exit 6 and 6 until the queued fix lands).
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    [z : i64 6]
    (set! v 5)
    (+
      z
      (-
        a
        (unsafe
          (ptr-read p))))))