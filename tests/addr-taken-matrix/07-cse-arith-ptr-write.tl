;; common subexpression elimination of (* v 2) across a store through &v.
;; Expected exit 81 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [t1 : i64 (* v 2)]
    (unsafe
      (ptr-write! p 3))
    (let
      [t2 : i64 (* v 2)]
      (+ (- t1 t2) 5))))