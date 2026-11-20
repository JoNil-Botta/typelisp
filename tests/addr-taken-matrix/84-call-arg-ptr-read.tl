;; the call argument is read through &v after a set! of v.
;; Expected exit 11 at --opt-level 0 (opt1 and opt2 exit 3 and 3 until the queued fix lands).
(define (double [x : i64]) : i64
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
    (+
      a
      (double
        (unsafe
          (ptr-read p))))))