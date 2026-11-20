;; load-CSE: the forwarded value is used as a loop bound.
;; Expected exit 40 at --opt-level 0 (opt1 and opt2 exit 37 and 37 until the queued fix lands).
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! v 3)
    (let
      [b : i64
        (unsafe
          (ptr-read p))]
      [acc : i64 0]
      [i : i64 0]
      (while (< i b)
        (set! acc (+ acc i))
        (set! i (+ i 1)))
      (+ a (+ acc 36)))))