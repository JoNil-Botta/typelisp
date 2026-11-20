;; #8672: `bounds_dom` folded a comparison of an address-taken local to a constant
;; taken from before the store. Expected exit 42 (opt2 exited 2).
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
    (if (= y 1)
      (if (= x 99)
        42
        2)
      1)))