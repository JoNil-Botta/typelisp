;; `y` is a copy of `x` taken before the store through `p`, so a guard on `y`
;; decides nothing about `x` after it: guard_dedup decided the second guard
;; from the first (#8785). Exits 42; opt2 exited 2.
(define (write-99 [p : (MutPtr i64)]) : unit
  (unsafe
    (ptr-write! p 99)))

(define (main) : i64
  (let
    [x : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [y : i64 x]
    (write-99 p)
    (if (< y 2)
      (if (< x 5)
        2
        42)
      1)))