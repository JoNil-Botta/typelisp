;; Refs #8913: the issue's reproducer. `b` copies `a`, which was built from the
;; address-taken `x` before the store through `px`, so `b.x` keeps 41 while `x`
;; reads the stored 3. At opt2 successor sinking moved the read of `x` into the
;; `then` arm, below the store, and the program exited 6. Exits 44.
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