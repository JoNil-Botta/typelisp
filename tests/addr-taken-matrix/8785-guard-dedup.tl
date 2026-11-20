;; #8785 case 2: `guard_dedup` decided a guard on the local from a guard on a copy
;; taken before the store. Expected exit 42 (opt2 exited 2).
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