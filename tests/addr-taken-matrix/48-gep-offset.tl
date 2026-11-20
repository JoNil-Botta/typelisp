;; a pointer offset whose local addend is rewritten through its address.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (sum-from [p : (MutPtr i64)] [k : i64]) : i64
  (let
    [off : i64 3]
    [po : (MutPtr i64)
      (unsafe
        (ptr-addr-of off))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i k)
      (set!
        acc
        (+
          acc
          (unsafe
            (ptr-read (ptr-offset p off)))))
      (unsafe
        (ptr-write! po 0))
      (set! i (+ i 1)))
    acc))

(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    (+ 36 (sum-from p 3))))