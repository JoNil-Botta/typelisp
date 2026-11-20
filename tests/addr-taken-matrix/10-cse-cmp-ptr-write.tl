;; CSE of (< v 20) across a store through &v.
;; Expected exit 40 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [t1 : bool (< v 20)]
    (unsafe
      (ptr-write! p 5))
    (let
      [t2 : bool (< v 20)]
      (if (= t1 t2)
        7
        40))))