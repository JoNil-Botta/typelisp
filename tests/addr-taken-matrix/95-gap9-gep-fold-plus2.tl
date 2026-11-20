;; gep displacement from (+ j 2) with j rewritten through its address.
;; Expected exit 40 at --opt-level 0, 1 and 2.
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
    [k : i64 (+ j 2)]
    (unsafe
      (ptr-write! pj 3))
    (+
      36
      (unsafe
        (ptr-read (ptr-offset base k))))))