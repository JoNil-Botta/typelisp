;; two locals with disjoint lifetimes; the address-taken one could share a slot.
;; Expected exit 47 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [_p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [w : i64 7]
    (set! v 5)
    (+ (+ 35 w) v)))