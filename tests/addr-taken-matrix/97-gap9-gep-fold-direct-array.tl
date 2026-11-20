;; a checked array index built from an address-taken local before a store to it.
;; Expected exit 39 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [j : i64 1]
    [pj : (MutPtr i64)
      (unsafe
        (ptr-addr-of j))]
    [k : i64 (+ j 1)]
    (unsafe
      (ptr-write! pj 4))
    (+ 36 (array-ref items k))))