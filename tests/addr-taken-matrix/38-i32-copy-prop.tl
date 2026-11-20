;; i32 local: a copy taken before the store, compared after it.
;; Expected exit 37 at --opt-level 0, 1 and 2.
(define (main) : i64
  (let
    [v : i32 (cast 41 : i32)]
    [p : (MutPtr i32)
      (unsafe
        (ptr-addr-of v))]
    [c : i32 v]
    (unsafe
      (ptr-write! p (cast 5 : i32)))
    (+ 1 (- (cast c : i64) (cast v : i64)))))