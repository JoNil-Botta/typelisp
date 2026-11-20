;; load-CSE on a bool local across a direct set! of it.
;; Expected exit 40 at --opt-level 0 (opt1 and opt2 exit 7 and 7 until the queued fix lands).
(define (main) : i64
  (let
    [f : bool true]
    [p : (MutPtr bool)
      (unsafe
        (ptr-addr-of f))]
    [a : bool
      (unsafe
        (ptr-read p))]
    (set! f false)
    (let
      [b : bool
        (unsafe
          (ptr-read p))]
      (if (= a b)
        7
        40))))