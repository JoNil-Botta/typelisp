;; the loop condition reads the bound through its address every iteration.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [n : i64 10]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (<
      i
      (unsafe
        (ptr-read pn)))
      (set! acc (+ acc (+ i 1)))
      (unsafe
        (ptr-write! pn 4))
      (set! i (+ i 1)))
    (+ acc 32)))