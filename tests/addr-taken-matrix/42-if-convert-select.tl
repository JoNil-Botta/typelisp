;; two ifs on the same expression of v, a store through &v between them.
;; Expected exit 41 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i64 41]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [t1 : i64
      (if (< v 20)
        1
        0)]
    (unsafe
      (ptr-write! p 5))
    (let
      [t2 : i64
        (if (< v 20)
          10
          0)]
      (+ (+ 31 t1) t2))))