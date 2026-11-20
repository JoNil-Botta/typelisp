;; load-CSE: two separately taken addresses of the same local.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 1]
    [p1 : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [p2 : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p1))]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read p2))]
      (+ a b))))