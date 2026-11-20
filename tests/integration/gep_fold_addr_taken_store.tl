;; #9420 GAP9: the backend gep displacement fold must refuse an address-taken
;; base. A store through the base address redefines it between the offset add
;; and the access, so folding the displacement would re-read the new value.
;; Exits 39 at opt0/1/2 (opt0 is the oracle).
;; a gep displacement computed from an address-taken local before a store to it.
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
    [k : i64 (+ j 1)]
    (unsafe
      (ptr-write! pj 4))
    (+
      36
      (unsafe
        (ptr-read (ptr-offset base k))))))