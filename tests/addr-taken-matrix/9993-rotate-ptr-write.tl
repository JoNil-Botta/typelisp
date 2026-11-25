;; rotate fusion: an intervening store through &x between shr/shl and bit-or
;; must not fuse into a rotate reading the mutated x.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(define (mid-write [x : u32]) : u32
  (let
    [p : (MutPtr u32)
      (unsafe
        (ptr-addr-of x))]
    [lo : u32 (shr x (cast 7 : u64))]
    (unsafe
      (ptr-write! p (cast 0 : u32)))
    (bit-or lo (shl x (cast 25 : u64)))))

(define (post-write [x : u32]) : u32
  (let
    [p : (MutPtr u32)
      (unsafe
        (ptr-addr-of x))]
    [lo : u32 (shr x (cast 7 : u64))]
    [hi : u32 (shl x (cast 25 : u64))]
    (unsafe
      (ptr-write! p (cast 0 : u32)))
    (bit-or lo hi)))

(define (main) : i64
  (let
    [x : u32 (cast 0x89abcdef : u32)]
    (if (and
      (= (mid-write x) (cast 0x0113579b : u32))
      (= (post-write x) (cast 0xdf13579b : u32)))
      42
      1)))