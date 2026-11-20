;; load-CSE: v is set in both arms of an if between the two loads.
;; Expected exit 6 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [a : i64
      (unsafe
        (ptr-read p))]
    (if (= (io.arg-count) 1)
      (set! v 5)
      (set! v 7))
    (+
      a
      (unsafe
        (ptr-read p)))))