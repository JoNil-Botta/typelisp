;; load-CSE: each branch loads *p and sets v; the join loads *p again.
;; Expected exit 42 at --opt-level 0, 1 and 2.
(import stdlib.io)

(define (main) : i64
  (let
    [v : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of v))]
    [x : i64 0]
    (if (= (io.arg-count) 1)
      (begin
        (set!
          x
          (unsafe
            (ptr-read p)))
        (set! v 5))
      (begin
        (set! x 9)
        (set! v 5)))
    (+
      36
      (+
        x
        (unsafe
          (ptr-read p))))))