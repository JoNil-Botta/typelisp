;; loop-invariant hoisting of (* v 7) against a direct set! in the loop.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 5]
    [_p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 3)
      (set! acc (+ acc (* v 7)))
      (set! v 2)
      (set! i (+ i 1)))
    (- acc 21)))