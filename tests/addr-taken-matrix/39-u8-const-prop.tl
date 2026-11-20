;; u8 local: constant propagation across a store through &v.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : u8 (cast 41 : u8)]
    [p : (MutPtr u8)
      (unsafe
        (ptr-addr-of v))]
    (unsafe
      (ptr-write! p (cast 5 : u8)))
    (+ 1 (cast v : i64))))