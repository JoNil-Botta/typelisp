;; load-CSE: two direct set!s of v between the two loads.
;; Expected exit 7 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! v 5)
    (let
      [seen : i64 v]
      (set! v 6)
      (+
        a
        (unsafe
          (ptr-read p))
        (- seen 5)))))