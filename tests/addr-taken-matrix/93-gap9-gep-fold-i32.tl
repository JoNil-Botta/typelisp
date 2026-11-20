;; gep displacement from an address-taken i32 local written through its pointer.
;; Expected exit 39 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [items : (Array i64 8) (array 1 2 3 4 5 6 7 8)]
    [j : i32 (cast 1 : i32)]
    [pj : (MutPtr i32)
      (unsafe
        (ptr-addr-of j))]
    [base : (MutPtr i64)
      (unsafe
        (ptr-addr-of (array-ref items 0)))]
    [k : i64 (+ (cast j : i64) 1)]
    (unsafe
      (ptr-write! pj (cast 4 : i32)))
    (+
      36
      (unsafe
        (ptr-read (ptr-offset base k))))))