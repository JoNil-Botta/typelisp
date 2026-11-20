;; i32 local: constant propagation across a store through &v.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i32 (cast 41 : i32)]
    [p : (MutPtr i32)
      (unsafe
        (ptr-addr-of v))]
    (unsafe
      (ptr-write! p (cast 5 : i32)))
    (+ 1 (cast v : i64))))