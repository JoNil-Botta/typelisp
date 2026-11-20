;; gep displacement from an address-taken offset inside a loop.
;; Expected exit 37 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [j : i64 1]
    [pj : (MutPtr i64)
      (unsafe
        (ptr-addr-of j))]
    [base : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    [acc : i64 0]
    [i : i64 0]
    (while (< i 2)
      (let
        [k : i64 (+ j 1)]
        (set!
          acc
          (+
            acc
            (unsafe
              (ptr-read (ptr-offset base k))))))
      (unsafe
        (ptr-write! pj 3))
      (set! i (+ i 1)))
    (+ 29 acc)))