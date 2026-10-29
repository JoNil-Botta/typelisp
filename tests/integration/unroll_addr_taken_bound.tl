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
    ;; a=1: n=100, then 4 after the first trip; i=0..3 -> 4*2 + 3*(0+1+2+3) + 16 = 42.
    (+ acc 16)))