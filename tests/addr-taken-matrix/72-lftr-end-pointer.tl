;; a pointer-walking loop whose length is lowered through its own address.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (sum-n [p : (MutPtr i64)] [n : i64]) : i64
  (let
    [pn : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i n)
      (set!
        acc
        (+
          acc
          (unsafe
            (ptr-read (ptr-offset p i)))))
      (unsafe
        (ptr-write! pn 4))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [items : (Array i64 16) (array 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    (+ 32 (sum-n p 10))))