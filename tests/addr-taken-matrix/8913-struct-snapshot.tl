;; #8913: a struct built from an address-taken local, copied, then the local
;; rewritten through its address: the copy kept the old field. Expected exit 44
;; (opt2 exited 6).
(import stdlib.io)

(defstruct P
  (x i64)
  (y i64))

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
    [a : P (P x 0)]
    [b : P a]
    (unsafe
      (ptr-write! px 3))
    (if (> (sink (io.arg-count)) 0)
      (+ b.x x)
      0)))