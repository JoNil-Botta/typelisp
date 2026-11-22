;; GAP9 gep fold: the index offset is a copy of an address-taken local, and a
;; callee holding its address stores before the read.
;; Expected exit 34 at --opt-level 0, 1 and 2.
(define (store5 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 5)))

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
    (store5 pj)
    (+
      30
      (unsafe
        (ptr-read (ptr-offset base k))))))