;; i32 local: a direct read, a set!, then a read through &v.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i32 (cast 1 : i32)]
    [p : (MutPtr i32)
      (unsafe
        (ptr-addr-of v))]
    [a : i32 v]
    (set! v (cast 5 : i32))
    (let
      [b : i32
        (unsafe
          (ptr-read p))]
      (cast (+ (cast a : i64) (cast b : i64)) : i64))))