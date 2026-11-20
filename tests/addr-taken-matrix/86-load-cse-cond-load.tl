;; load-CSE: the second load sits in a conditional arm after a set! of v.
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
    (set! v 5)
    (let
      [b : i64
        (if (= (io.arg-count) 1)
          (unsafe
            (ptr-read p))
          0)]
      (+ a b))))