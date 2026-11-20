;; u8 local: CSE of an expression on v across a store through &v.
;; Expected exit 15 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : u8 (cast 3 : u8)]
    [p : (MutPtr u8)
      (unsafe
        (ptr-addr-of v))]
    [a : i64 (* (cast v : i64) 7)]
    (unsafe
      (ptr-write! p (cast 5 : u8)))
    (let
      [b : i64 (* (cast v : i64) 7)]
      (+ 1 (- b a)))))