;; load-CSE: the pointer passes through an identity function.
;; Expected exit 6 at --opt-level 0 (opt1 and opt2 exit 2 and 2 until the queued fix lands).
(define (same [p : (MutPtr i64)]) : (MutPtr i64)
  p)

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [q : (MutPtr i64) (same p)]
    [a : i64
      (unsafe
        (ptr-read q))]
    (set! v 5)
    (let
      [b : i64
        (unsafe
          (ptr-read q))]
      (+ a b))))