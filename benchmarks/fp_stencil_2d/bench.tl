;# benchmarks/fp_stencil_2d/bench.tl - 5-point 2D Jacobi heat-diffusion stencil.
;#
;# Equivalent to benchmarks/fp_stencil_2d/baseline.c. Allocates two ping-pong
;# `n x n` `f64` grids with clamped Dirichlet borders and a deterministic
;# asymmetric interior initial temperature field, runs `steps` 5-point Jacobi
;# updates (`0.4 * center + 0.15 * ((left + right) + (up + down))`), and folds
;# the exact IEEE-754 binary64 bit pattern of every cell in the final grid into
;# a wrapping 64-bit FNV-1a checksum. Grid dimension and step count are runtime
;# CLI arguments.
(import stdlib.io)
(import stdlib.math)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector f64 core) as f64vec)

(define fs-hash-basis : u64
  0xcbf29ce484222325)
(define fs-hash-prime : u64
  1099511628211)

(define (fs-mix [h : u64] [v : u64]) : u64
  (* (bit-xor h v) fs-hash-prime))

(define (fs-zero-vec [total : i64]) : f64vec.Vec
  (let
    [v : f64vec.Vec (f64vec.with-capacity total)]
    [i : i64 0]
    (while (< i total)
      (f64vec.push! v 0.0)
      (set! i (+ i 1)))
    v))

(define (fs-init-grids
  [a : (&mut a (Slice f64))]
  [b : (&mut b (Slice f64))]
  [n : i64]) : unit
  (let
    [last : i64 (- n 1)]
    [inv-last : f64 (/ 1.0 (cast last : f64))]
    [r : i64 0]
    (while (< r n)
      (let
        [row-base : i64 (* r n)]
        [c : i64 0]
        (while (< c n)
          (let
            [val : f64
              (cond
                [(= r 0) 100.0]
                [(= r last) 0.0]
                [(= c 0) (* 50.0 (- 1.0 (* (cast r : f64) inv-last)))]
                [(= c last) (* 25.0 (- 1.0 (* (cast r : f64) inv-last)))]
                [else (* (cast (% (+ (* r 7) (* c 13)) 97) : f64) 0.25)])]
            (set! (array-ref a (+ row-base c)) val)
            (set! (array-ref b (+ row-base c)) val))
          (set! c (+ c 1))))
      (set! r (+ r 1)))))

(define (fs-step
  [src : (& src (Slice f64))]
  [dst : (&mut dst (Slice f64))]
  [n : i64]) : unit
  (let
    [limit : i64 (- n 1)]
    [r : i64 1]
    (while (< r limit)
      (let
        [row-base : i64 (* r n)]
        [up-base : i64 (- row-base n)]
        [dn-base : i64 (+ row-base n)]
        [c : i64 1]
        (while (< c limit)
          (let
            [idx : i64 (+ row-base c)]
            [center : f64 (array-ref src idx)]
            [left : f64 (array-ref src (- idx 1))]
            [right : f64 (array-ref src (+ idx 1))]
            [up : f64 (array-ref src (+ up-base c))]
            [down : f64 (array-ref src (+ dn-base c))]
            [neighbors : f64 (+ (+ left right) (+ up down))]
            (set! (array-ref dst idx) (+ (* 0.4 center) (* 0.15 neighbors))))
          (set! c (+ c 1))))
      (set! r (+ r 1)))))

(define (fs-hash-grid [grid : (& grid (Slice f64))] [total : i64]) : u64
  (let
    [h : u64 fs-hash-basis]
    [i : i64 0]
    (while (< i total)
      (set! h (fs-mix h (math.f64-to-bits (array-ref grid i))))
      (set! i (+ i 1)))
    h))

(define (fs-bench [n : i64] [steps : i64]) : u64
  (let
    [total : i64 (* n n)]
    [buf-a : f64vec.Vec (fs-zero-vec total)]
    [buf-b : f64vec.Vec (fs-zero-vec total)]
    [step : i64 0]
    (fs-init-grids
      (f64vec.view-mut (&mut buf-a))
      (f64vec.view-mut (&mut buf-b))
      n)
    (while (< (+ step 1) steps)
      (fs-step (f64vec.view (& buf-a)) (f64vec.view-mut (&mut buf-b)) n)
      (fs-step (f64vec.view (& buf-b)) (f64vec.view-mut (&mut buf-a)) n)
      (set! step (+ step 2)))
    (if (< step steps)
      (begin
        (fs-step (f64vec.view (& buf-a)) (f64vec.view-mut (&mut buf-b)) n)
        (fs-hash-grid (f64vec.view (& buf-b)) total))
      (fs-hash-grid (f64vec.view (& buf-a)) total))))

(define (main) : i64
  (let
    [n : i64 (string.>int (io.arg 1))]
    [steps : i64 (string.>int (io.arg 2))]
    (io.println "{}" (fs-bench n steps))
    0))