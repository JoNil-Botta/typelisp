;; #9420 case 6: strength reduction treated the address-taken addend as invariant.
;; Expected exit 42 (opt2 exited 118).
(import stdlib.io)

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [x : i64 (+ 40 n)]
    [px : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i (+ n 3))
      (set! acc (+ acc (+ x (* i 3))))
      (unsafe
        (ptr-write! px (+ i 100)))
      (set! i (+ i 1)))
    (- acc 320)))