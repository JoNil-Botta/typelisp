;; A loop that keeps a lagged copy of its counter (`a` takes the value `i` had
;; at the top of the iteration) while a call in the body pushes both values into
;; callee-saved registers. The back edge's phis read in parallel: `a` must get
;; the OLD `i`, not the incremented one. Conservative liveness once treated
;; `a`'s read of `i` as a use after `i`'s own phi, ended `i`'s live range at the
;; increment, and let `i` and `i + 1` share a register, so `a` saw `i + 1`.
;; Two callers keep `probe` out of line, which is what puts the call in the loop.
(import stdlib.io)
(import stdlib.string)

(define (probe [values : (& values (__tl_dyn-array i64))] [bias : i64]) : i64
  (let
    [i : i64 0]
    [total : i64 bias]
    (begin
      (while (< i (array-length values))
        (begin
          (set! total (+ (* total 3) (array-ref values i)))
          (set! i (+ i 1))))
      total)))

;; A prefix update before the call.
(define (lag-prefix [values : (& values (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [i : i64 0]
    [a : i64 100]
    [d : i64 0]
    [r : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! d (- d 1))
          (set! r (- a (probe values 0)))
          (set! a i)
          (set! i (+ i 1))))
      (+ (* r 1000) d))))

;; The lagged copy alone.
(define (lag-plain [values : (& values (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [i : i64 0]
    [a : i64 100]
    [r : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! r (- a (probe values 0)))
          (set! a i)
          (set! i (+ i 1))))
      r)))

;; The lagged value feeds a sum rather than the call's neighbour.
(define (lag-sum [values : (& values (__tl_dyn-array i64))] [n : i64]) : i64
  (let
    [i : i64 0]
    [a : i64 100]
    [s : i64 0]
    [r : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! s (+ s a))
          (set! r (probe values 0))
          (set! a i)
          (set! i (+ i 1))))
      (+ s r))))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [n : i64 (string.>int (io.arg 1))]
    (begin
      (io.println "{}" (lag-prefix (& values) n))
      (io.println "{}" (lag-plain (& values) n))
      (io.println "{}" (lag-sum (& values) n))
      42)))