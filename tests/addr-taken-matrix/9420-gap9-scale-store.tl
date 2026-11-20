;; GAP9 gep fold: a doubled index derived from an address-taken local, with a
;; store through &j between the index computation and the element read.
;; Expected exit 33 at --opt-level 0, 1 and 2.
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
    [k : i64 (+ j j)]
    (unsafe
      (ptr-write! pj 3))
    (+
      30
      (unsafe
        (ptr-read (ptr-offset base k))))))