;; load-CSE on a u8 local across a direct set! of it.
;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
(define (main) : i64
  (let
    [v : u8 (cast 1 : u8)]
    [p : (MutPtr u8)
      (unsafe
        (ptr-addr-of v))]
    [a : u8
      (unsafe
        (ptr-read p))]
    (set! v (cast 5 : u8))
    (let
      [b : u8
        (unsafe
          (ptr-read p))]
      (cast (+ (cast a : i64) (cast b : i64)) : i64))))