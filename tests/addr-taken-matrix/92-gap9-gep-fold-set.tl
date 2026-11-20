;; gep displacement from an address-taken local written by a direct set!.
;; Expected exit 39 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [j : i64 1]
    [base : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    [k : i64 (+ j 1)]
    (set! j 4)
    (+
      36
      (unsafe
        (ptr-read (ptr-offset base k))))))