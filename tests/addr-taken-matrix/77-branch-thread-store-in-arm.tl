;; the flag store sits in the first conditional, the test in a later block.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [f : bool (= (io.arg-count) 1)]
    [pf : (MutPtr bool)
      (unsafe
        (ptr-addr-of f))]
    [x : i64 0]
    (if f
      (begin
        (unsafe
          (ptr-write! pf false))
        (set! x 0))
      (set! x 50))
    (+
      x
      (if f
        10
        40))))