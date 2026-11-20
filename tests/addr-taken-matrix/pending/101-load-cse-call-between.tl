;; load-CSE: a call that does not write through &v sits between the loads.
;; Expected exit 2 at --opt-level 0 (opt1 and opt2 exit 6 and 6 until the queued fix lands).
(define (twice [x : i64]) : i64
  (* x 2))

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (set! v 5)
    (let
      [z : i64 (twice 3)]
      [b : i64
        (unsafe
          (ptr-read p))]
      (- (+ z a) b))))