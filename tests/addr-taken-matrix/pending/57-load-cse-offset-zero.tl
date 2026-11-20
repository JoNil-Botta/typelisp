;; load-CSE: the load address is a zero pointer offset of &v.
;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 6 and 2 until the queued fix lands).
(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read (ptr-offset p 0)))]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read (ptr-offset p 0)))]
      (+ a b))))