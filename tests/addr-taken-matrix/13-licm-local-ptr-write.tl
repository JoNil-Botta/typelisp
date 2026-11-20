;; loop-invariant hoisting of v across a per-iteration store through &v.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 4)
      (set! acc (+ acc v))
      (unsafe
        (ptr-write! p (* (+ i 1) 10)))
      (set! i (+ i 1)))
    (- acc 59)))