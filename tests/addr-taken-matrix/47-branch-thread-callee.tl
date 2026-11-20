;; branch threading where a callee clears the address-taken flag.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(define (clear [p : (MutPtr bool)])
  (unsafe
    (ptr-write! p false)))

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
    (clear pf)
    (+
      x
      (if f
        10
        40))))