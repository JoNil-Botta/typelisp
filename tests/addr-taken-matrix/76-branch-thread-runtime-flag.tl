;; branch threading on a runtime bool flag whose address is taken.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [f : bool (= (io.arg-count) 1)]
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