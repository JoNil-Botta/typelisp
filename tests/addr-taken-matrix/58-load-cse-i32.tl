;; load-CSE on an i32 local across a direct set! of it.
;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
(define (main) : i64
  (let
    [v : i32 (cast 1 : i32)]
    [p : (MutPtr i32)
      (unsafe
        (ptr-addr-of v))]
    [a : i32
      (unsafe
        (ptr-read p))]
    (set! v (cast 5 : i32))
    (let
      [b : i32
        (unsafe
          (ptr-read p))]
      (cast (+ (cast a : i64) (cast b : i64)) : i64))))