;# benchmarks/spmd_foreach_2d/bench.tl - rank-2 SPMD foreach micro-benchmark
;# (#7191).
;#
;# Equivalent to benchmarks/spmd_foreach_2d/baseline.c. Each pass maps
;# `out[y * w + x] = a[y * w + x] + b[y * w + x] + r` over two 8-row domains:
;# width 256, which every gang width divides (full gangs only), and width 255,
;# which leaves a partial tail on every row (repeated tails). A rank-2 foreach
;# runs each row as row-local gangs over row-major views, so this measures the
;# per-row origin and guard work as well as the gangs. TypeLisp `+` wraps modulo
;# 2^64 (SPEC), matching C `uint64_t`, so both programs produce the identical
;# exit code.
;#
;# The arrays are cache-resident and the outer repetition loop makes the work
;# runtime-dominant; the per-pass `r` term blocks kernel hoisting and the
;# `base-reps + (io.arg-count)` trip count (io.arg-count is 1 with no extra
;# arguments, matching C `argc`) keeps the result deterministic while
;# preventing whole-loop constant folding. Each pass folds a different element
;# of each output into the accumulator so the stores cannot be eliminated.
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(define rows : i64
  8)
(define full-width : i64
  256)
(define tail-width : i64
  255)
(define base-reps : i64
  125000)

(define (make-buffer [capacity : i64]) : i64v.Vec
  (let
    [out : i64v.Vec (i64v.with-capacity capacity)]
    [i : i64 0]
    (while (< i capacity)
      (i64v.push-ref! (&mut out) 0)
      (set! i (+ i 1)))
    out))

(define (init [a : (&mut a (Slice i64))] [b : (&mut b (Slice i64))] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (set! (array-ref a i) (+ i 1))
      (set! (array-ref b i) (* i 2))
      (set! i (+ i 1)))))

(define (pass
  [out : (&mut out (Slice i64))]
  [a : (&mut a (Slice i64))]
  [b : (&mut b (Slice i64))]
  [w : i64]
  [r : i64]) : unit
  (foreach
    ([y : i64 0 rows] [x : i64 0 w])
    (set!
      (array-ref out (+ (* y w) x))
      (+ (+ (array-ref a (+ (* y w) x)) (array-ref b (+ (* y w) x))) r))))

(define (main) : i64
  (let
    [n : i64 (* rows full-width)]
    [a : i64v.Vec (make-buffer n)]
    [b : i64v.Vec (make-buffer n)]
    [full : i64v.Vec (make-buffer n)]
    [tail : i64v.Vec (make-buffer n)]
    [a-view : (&mut a (Slice i64)) (i64v.view-mut (&mut a))]
    [b-view : (&mut b (Slice i64)) (i64v.view-mut (&mut b))]
    [full-view : (&mut full (Slice i64)) (i64v.view-mut (&mut full))]
    [tail-view : (&mut tail (Slice i64)) (i64v.view-mut (&mut tail))]
    [reps : i64 (+ base-reps (io.arg-count))]
    [acc : i64 0]
    [r : i64 0]
    (init a-view b-view n)
    (while (< r reps)
      (pass full-view a-view b-view full-width r)
      (pass tail-view a-view b-view tail-width r)
      (set!
        acc
        (+
          acc
          (+
            (array-ref full-view (% r (* rows full-width)))
            (array-ref tail-view (% r (* rows tail-width))))))
      (set! r (+ r 1)))
    (bit-and acc 255)))