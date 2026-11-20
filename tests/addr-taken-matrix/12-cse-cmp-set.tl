;; CSE of a compare on v across a direct set! of v.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 3]
    [_p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : bool (< v 10)]
    (set! v 30)
    (let
      [b : bool (< v 10)]
      (if (= a b)
        7
        40))))