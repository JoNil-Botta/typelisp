;; copy propagation of an address-taken local across a store through the pointer.
;; Expected exit 37 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [c : i64 v]
    (unsafe
      (ptr-write! p 5))
    (+ 1 (- c v))))