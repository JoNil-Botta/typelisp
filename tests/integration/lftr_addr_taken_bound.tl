(import stdlib.io)

;; The store-bearing diamond keeps ordinary unrolling out of this LFTR witness.
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
      (if (>
        (unsafe
          (ptr-read pn))
        50)
        (unsafe
          (ptr-write! pn 4))
        (unsafe
          (ptr-write! pn 5)))
      (set! i (+ i 1)))
    ;; Trips i=0..4: 5*2 + 3*(0+1+2+3+4) + 16 = 56.
    (+ acc 16)))