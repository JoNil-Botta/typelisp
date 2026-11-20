;; #8785 case 1: `gvn` numbered a compare of the local before the store the same as
;; one after it. Expected exit 42 (opt2 exited 2).
(define (write-99 [p : (MutPtr i64)]) : unit
  (unsafe
    (ptr-write! p 99)))

(define (main) : i64
  (let
    [x : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    (if (= x 1)
      (begin
        (write-99 p)
        (if (= x 1)
          2
          42))
      1)))