;; constant propagation: literal initializer, rewritten through its own address.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    (unsafe
      (ptr-write! p 5))
    (+ 1 v)))