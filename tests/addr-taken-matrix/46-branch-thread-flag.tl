;; branch threading on an address-taken bool flag.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [f : bool true]
    [pf : (MutPtr bool)
      (unsafe
        (ptr-addr-of f))]
    [x : i64
      (if f
        0
        50)]
    (unsafe
      (ptr-write! pf false))
    (+
      x
      (if f
        10
        40))))