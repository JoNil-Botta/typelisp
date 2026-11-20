;; #9420 case 7: `unroll` read the address-taken trip bound once for its clone.
;; Expected exit 42 (opt2 exited 98).
(import stdlib.io)

(define (main) : i64
  (let
    [a : i64 (io.arg-count)]
    [n : i64 (+ a 99)]
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [c : i64 (+ a 1)]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set! acc (+ acc (+ c (* i 3))))
      (unsafe
        (ptr-write! pn 4))
      (set! i (+ i 1)))
    (+ acc 16)))