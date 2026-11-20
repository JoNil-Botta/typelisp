;; loop-invariant hoisting of v with the store in a callee.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (storeit [p : (MutPtr i64)] [x : i64])
  (unsafe
    (ptr-write! p x)))

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
      (storeit p (* (+ i 1) 10))
      (set! i (+ i 1)))
    (- acc 59)))