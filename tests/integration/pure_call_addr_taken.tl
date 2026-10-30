;; Refs #9420, section 4: pointer stores change local storage.
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
    ;; argc 1: sink(41) + sink(3) = 44
    (+ (sink a) (sink x))))