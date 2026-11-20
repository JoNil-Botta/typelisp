;; load-CSE: one branch loads *p, the join sets v, a later block loads *p.
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
      (set!
        x
        (unsafe
          (ptr-read p)))
      (set! x 0))
    (set! v 5)
    (+
      36
      (+
        x
        (unsafe
          (ptr-read p))))))