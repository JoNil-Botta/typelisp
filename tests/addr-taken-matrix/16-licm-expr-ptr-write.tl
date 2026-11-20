;; loop-invariant hoisting of (* v 2) across a store through &v.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 3)
      (set! acc (+ acc (* v 2)))
      (unsafe
        (ptr-write! p (+ 3 (* i 2))))
      (set! i (+ i 1)))
    (- acc 56)))