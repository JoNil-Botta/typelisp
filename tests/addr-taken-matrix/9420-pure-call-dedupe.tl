;; #9420 case 4: pure-call deduplication reused a call on a copy taken before the
;; store for the call on the local. Expected exit 44 (opt2 exited 82).
(import stdlib.io)

(define (sink [x : i64]) : i64
  (if (> x 1000000)
    (sink (- x 1))
    x))

(define (main) : i64
  (let
    [x : i64 (+ 40 (io.arg-count))]
    [px : (MutPtr i64)
      (unsafe
        (ptr-addr-of x))]
    [a : i64 x]
    (unsafe
      (ptr-write! px 3))
    (+ (sink a) (sink x))))