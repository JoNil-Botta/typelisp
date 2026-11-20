;; load-CSE: two loads through &v added across a direct set! of v.
;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
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
      [b : i64
        (unsafe
          (ptr-read p))]
      (+ a b))))