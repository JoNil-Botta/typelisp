;; u8 local: a direct read, a set!, then a read through &v.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : u8 (cast 1 : u8)]
    [p : (MutPtr u8)
      (unsafe
        (ptr-addr-of v))]
    [a : u8 v]
    (set! v (cast 5 : u8))
    (let
      [b : u8
        (unsafe
          (ptr-read p))]
      (cast (+ (cast a : i64) (cast b : i64)) : i64))))