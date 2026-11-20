;; loop-invariant hoisting of v against a direct set! inside the loop.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [_p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 3)
      (set! acc (+ acc v))
      (set! v 4)
      (set! i (+ i 1)))
    (- acc 7)))