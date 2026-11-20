;; direct set! of a value read before it, then a read through the pointer.
;; Expected exit 37 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 v]
    (set! v 5)
    (+
      1
      (-
        a
        (unsafe
          (ptr-read p))))))