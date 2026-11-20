;; gep displacement from an address-taken local stored through a callee.
;; Expected exit 39 at --opt-level 0, 1 and 2.
(define (store4 [p : (MutPtr i64)])
  (unsafe
    (ptr-write! p 4)))

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
    (store4 pj)
    (+
      36
      (unsafe
        (ptr-read (ptr-offset base k))))))