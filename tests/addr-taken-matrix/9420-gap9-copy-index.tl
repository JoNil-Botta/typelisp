;; GAP9 gep fold: the gep index is a copy taken before a store through the
;; source's address, and the copy feeds a scaled index.
;; Expected exit 33 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [j : i64 1]
    [pj : (MutPtr i64)
      (unsafe
        (ptr-addr-of j))]
    [c : i64 j]
    [base : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    (unsafe
      (ptr-write! pj 4))
    (+
      30
      (unsafe
        (ptr-read (ptr-offset base (+ c 1)))))))