;; load-CSE: the forwarded value is used as an array index.
;; Expected exit 26 at --opt-level 0 (opt1 and opt2 exit 22 and 22 until the queued fix lands).
(define (main) : i64
  (let
    [items : (Array i64 8) (array 10 11 12 13 14 15 16 17)]
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read p))]
      (+ (array-ref items a) (array-ref items b)))))